import XCTest
@testable import CadenciaCore

final class CyclistProfileTests: XCTestCase {
    let today = Day(year: 2026, month: 10, day: 29)
    let athlete = AthleteProfile(id: "i1", name: "Rider", ftp: 260, indoorFTP: 250, weightKg: 65)

    func ride(_ id: String, day: Day? = nil, type: String = "Ride") -> ActivitySummary {
        .init(id: id, name: "Private route name", type: type, startDateLocal: (day ?? today).date(), movingTime: 7200,
              distanceMeters: 60000, averageWatts: 190, rpe: 5, feel: 2, elevationGainMeters: 1000)
    }

    func brief(count: Int = 8, curve: [PowerCurvePoint] = [.init(seconds: 300, watts: 325)]) -> CyclistProfile.Brief {
        .init(locale: "es", newest: today, athlete: athlete, activities: (0..<count).map { ride("i\($0)", day: today.adding(days: -$0)) }, powerCurve: curve)
    }

    func json(type: String = "climber", confidence: String = "moderate", headline: String = "Your sustained power stands out") -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "riderType": type, "confidence": confidence, "headline": headline,
            "summary": "Your recorded riding suggests a climbing tendency, with limited evidence of maximal efforts.",
            "strengths": ["Your recorded 5-minute power is 325 W (5 W/kg)."],
            "development": ["Record a longer steady effort to understand sustained power."],
            "evidence": ["Eight rides with 1,000 m of ascent each."],
            "caveats": ["Recorded training does not establish fixed potential."]
        ])
    }

    func testBriefUsesOnlyEligibleWindowedRidesAndKeepsTerrainAndFeedback() throws {
        let oldest = today.adding(days: -179)
        let activities = [ride("valid"), ride("valid"), ride("boundary", day: oldest),
                          ride("old", day: oldest.adding(days: -1)), ride("future", day: today.adding(days: 1)),
                          ride("run", type: "Run"), ride("assisted", type: "EBikeRide")]
        let b = CyclistProfile.Brief(locale: "es", newest: today, athlete: athlete, activities: activities,
                                     powerCurve: [.init(seconds: 300, watts: 325), .init(seconds: 7, watts: 1000)])
        XCTAssertEqual(b.rides.count, 2)
        XCTAssertEqual(b.oldest, oldest)
        XCTAssertEqual(b.rides.first?.day, oldest)
        XCTAssertEqual(b.rides.last?.distanceKm, 60)
        XCTAssertEqual(b.rides.last?.elevationGainMeters, 1000)
        XCTAssertEqual(b.rides.last?.feel, 2)
        XCTAssertEqual(b.powerCurve.count, 1)
        XCTAssertEqual(b.powerCurve.first?.wattsPerKg, 5)
        XCTAssertEqual(b.ftp, 260, "Outdoor and indoor FTP stay distinct")
        XCTAssertEqual(b.indoorFTP, 250)
        XCTAssertFalse(try CyclistProfile.userMessage(b).contains("Private route name"))
    }

    func testMissingWeightDoesNotBecomeZeroOrProduceRelativePower() {
        var a = athlete
        a.weightKg = 0
        let b = CyclistProfile.Brief(locale: "en", newest: today, athlete: a, activities: [], powerCurve: [.init(seconds: 300, watts: 325)])
        XCTAssertNil(b.weightKg)
        XCTAssertNil(b.powerCurve.first?.wattsPerKg)
    }

    func testReportStoresAppOwnedCoverageAndSurvivesPersistence() throws {
        let date = Date(timeIntervalSince1970: 123)
        let report = try CyclistProfile.parse(json(), brief: brief(), model: "existing-model", now: date)
        XCTAssertEqual(report.riderType, .climber)
        XCTAssertEqual(report.rideCount, 8)
        XCTAssertEqual(report.oldest, today.adding(days: -179))
        XCTAssertEqual(report.generatedAt, date)
        XCTAssertEqual(report.model, "existing-model")
        XCTAssertEqual(try JSONDecoder().decode(CyclistProfile.Report.self, from: JSONEncoder().encode(report)), report)
    }

    func testSparseHistoryCannotBeGivenAConfidentSpeciality() throws {
        XCTAssertThrowsError(try CyclistProfile.parse(json(), brief: brief(count: 2), model: "m"))
        XCTAssertNoThrow(try CyclistProfile.parse(json(type: "developing", confidence: "limited"), brief: brief(count: 0, curve: []), model: "m"))
        XCTAssertThrowsError(try CyclistProfile.parse(json(confidence: "high"), brief: brief(), model: "m"))
        XCTAssertThrowsError(try CyclistProfile.parse(json(headline: "  "), brief: brief(), model: "m"))
        XCTAssertThrowsError(try CyclistProfile.parse(json(type: "invented"), brief: brief(), model: "m"))
    }

    func testClimberRequiresRelativePowerAndOutdoorTerrainEvidence() {
        var b = brief()
        b.weightKg = nil
        XCTAssertThrowsError(try CyclistProfile.parse(json(), brief: b, model: "m"))
        b = brief(curve: [])
        XCTAssertThrowsError(try CyclistProfile.parse(json(), brief: b, model: "m"))
        b = brief()
        for i in b.rides.indices { b.rides[i].indoor = true }
        XCTAssertThrowsError(try CyclistProfile.parse(json(), brief: b, model: "m"))
    }

    func testAutomaticGenerationNeverRepeatsAfterSavedAttemptOrReport() {
        XCTAssertTrue(CyclistProfile.shouldGenerateAutomatically(hasReport: false, attemptedAt: nil))
        XCTAssertFalse(CyclistProfile.shouldGenerateAutomatically(hasReport: false, attemptedAt: Date()), "Failed first attempt requires an explicit retry")
        XCTAssertFalse(CyclistProfile.shouldGenerateAutomatically(hasReport: true, attemptedAt: nil), "Manual generation before first appearance also prevents automatic work")
        XCTAssertFalse(CyclistProfile.shouldGenerateAutomatically(hasReport: true, attemptedAt: Date()))
    }

    func testIntervalsFetchesMatchingHistoryAndCurveWindowsAndDecodesElevation() async throws {
        let transport = FakeTransport(responses: [
            .init(status: 200, body: Data(#"{"id":"i1","weight":65}"#.utf8)),
            .init(status: 200, body: Data(#"[{"id":"ride","type":"Ride","start_date_local":"2026-10-28T08:00:00","moving_time":7200,"distance":60000,"total_elevation_gain":1350.5}]"#.utf8)),
            .init(status: 200, body: Data(#"{"list":[{"secs":[5,300],"values":[950,325]}]}"#.utf8))
        ])
        let client = IntervalsClient(transport: transport, credential: .apiKey("existing"))
        let b = try await client.cyclistProfileBrief(newest: today, locale: "es")
        XCTAssertEqual(transport.requests.count, 3)
        XCTAssertTrue(transport.requests.allSatisfy { $0.method == .get })
        let activitiesQuery = query(transport.requests[1].url)
        XCTAssertEqual(activitiesQuery["oldest"], b.oldest.iso)
        XCTAssertEqual(activitiesQuery["newest"], b.newest.iso)
        XCTAssertNil(activitiesQuery["limit"], "Do not silently truncate the six-month history")
        XCTAssertEqual(query(transport.requests[2].url)["curves"], "r.\(b.oldest.iso).\(b.newest.iso)")
        XCTAssertEqual(b.rides.first?.elevationGainMeters, 1351)
        XCTAssertEqual(b.powerCurve.last?.wattsPerKg, 5)
        XCTAssertFalse(b.powerCurveUnavailable)
    }

    func testUnavailableCurveIsExplicitButAuthFailuresAreNotSwallowed() async throws {
        func transport(status: Int) -> FakeTransport {
            FakeTransport(responses: [
                .init(status: 200, body: Data(#"{"id":"i1"}"#.utf8)),
                .init(status: 200, body: Data("[]".utf8)), .init(status: status, body: Data())
            ])
        }
        let b = try await IntervalsClient(transport: transport(status: 422), credential: .apiKey("k")).cyclistProfileBrief(newest: today, locale: "en")
        XCTAssertTrue(b.powerCurveUnavailable)
        XCTAssertTrue(b.powerCurve.isEmpty)
        do {
            _ = try await IntervalsClient(transport: transport(status: 401), credential: .apiKey("k")).cyclistProfileBrief(newest: today, locale: "en")
            XCTFail("Authentication failure must require reconnection")
        } catch { XCTAssertEqual(error as? HTTPError, .unauthorized) }
    }

    func testExistingActivityJSONWithoutElevationStillDecodes() throws {
        let encoded = try JSONEncoder().encode(ride("i1"))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "elevationGainMeters")
        let old = try JSONDecoder().decode(ActivitySummary.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(old.elevationGainMeters)
        XCTAssertEqual(old.id, "i1")
    }

    func testProfileUsesExistingCoachBackendAndLanguage() async throws {
        let output = String(decoding: json(), as: UTF8.self)
        let response = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": output]]]])
        let t = FakeTransport(responses: [.init(status: 200, body: response)])
        let endpoint = URL(string: "https://existing.example/chat/completions")!
        let coach = LLMCoach(transport: t, endpoint: endpoint, apiKey: "existing-key", model: "existing-model")
        let report = try await coach.cyclistProfile(brief())
        XCTAssertEqual(report.model, "existing-model")
        XCTAssertEqual(t.requests.first?.url, endpoint)
        XCTAssertEqual(t.requests.first?.headers["Authorization"], "Bearer existing-key")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: t.requests[0].body!) as? [String: Any])
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertTrue(messages[0]["content"]!.contains("language \"es\""))
        XCTAssertTrue(messages[0]["content"]!.contains("whole-ride feel cannot isolate"))
        XCTAssertTrue(messages[1]["content"]!.contains("elevationGainMeters"))
    }

    func testProfileAlsoUsesTheExistingChatGPTPlanRoute() async throws {
        let output = String(decoding: json(), as: UTF8.self)
        let delta = String(decoding: try JSONSerialization.data(withJSONObject: ["type": "response.output_text.delta", "delta": output]), as: UTF8.self)
        let sse = "data: \(delta)\n\ndata: {\"type\":\"response.completed\",\"response\":{\"id\":\"r\"}}\n\n"
        let t = FakeTransport(responses: [.init(status: 200, body: Data(sse.utf8))])
        let coach = LLMCoach(transport: t, backend: .chatGPTPlan(accessToken: "existing-plan"), model: "existing-model")
        let report = try await coach.cyclistProfile(brief())
        XCTAssertEqual(report.riderType, .climber)
        XCTAssertEqual(t.requests.first?.url, LLMCoach.responsesURL)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: t.requests[0].body!) as? [String: Any])
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual(body["model"] as? String, "existing-model")
        XCTAssertTrue((body["instructions"] as? String)?.contains("personal cyclist profile") == true)
    }

    func query(_ url: URL) -> [String: String] {
        Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
    }
}
