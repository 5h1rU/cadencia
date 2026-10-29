import XCTest
@testable import CadenciaCore

/// Records requests and replays canned responses.
final class FakeTransport: HTTPTransport, @unchecked Sendable {
    var responses: [HTTPResponse]
    var requests: [HTTPRequest] = []
    var error: Error?
    private let lock = NSLock()

    init(responses: [HTTPResponse] = [], error: Error? = nil) {
        self.responses = responses
        self.error = error
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        lock.lock(); defer { lock.unlock() }
        requests.append(request)
        if let error { throw error }
        guard !responses.isEmpty else { return HTTPResponse(status: 200, body: Data("{}".utf8)) }
        return responses.removeFirst()
    }
}

final class IntervalsClientTests: XCTestCase {
    func testAPIKeyUsesBasicAuthWithLiteralUsername() async throws {
        let t = FakeTransport(responses: [HTTPResponse(status: 200, body: Data(#"{"id":"i1","name":"Felipe","sportSettings":[{"types":["Ride","VirtualRide"],"ftp":240,"indoor_ftp":235,"power_zones":[55,75,90,105,120,150]}]}"#.utf8))])
        let client = IntervalsClient(transport: t, credential: .apiKey("secret"))
        let athlete = try await client.athlete()
        XCTAssertEqual(t.requests.first?.headers["Authorization"], "Basic " + Data("API_KEY:secret".utf8).base64EncodedString())
        XCTAssertEqual(t.requests.first?.url.absoluteString, "https://intervals.icu/api/v1/athlete/0")
        XCTAssertEqual(athlete.ftp, 240)
        XCTAssertEqual(athlete.workingFTP, 235, "indoor FTP wins for trainer prescriptions")
        XCTAssertEqual(athlete.powerZones.count, 6)
    }

    func testWellnessDecodesIntervalsFieldNames() async throws {
        let json = #"[{"id":"2026-10-28","ctl":62.1,"atl":78.4,"restingHR":54,"hrv":48.2,"sleepSecs":22320,"updated":"2026-10-28T09:37:12.000+0000"},{"id":"not-a-date"}]"#
        let t = FakeTransport(responses: [HTTPResponse(status: 200, body: Data(json.utf8))])
        let client = IntervalsClient(transport: t, credential: .oauth(accessToken: "tok", scopes: ["WELLNESS:READ"]))
        let days = try await client.wellness(oldest: Day(year: 2026, month: 9, day: 1), newest: Day(year: 2026, month: 10, day: 28))
        XCTAssertEqual(t.requests.first?.headers["Authorization"], "Bearer tok")
        XCTAssertEqual(t.requests.first?.url.query, "newest=2026-10-28&oldest=2026-09-01")
        XCTAssertEqual(days.count, 1, "rows without a valid day are dropped")
        XCTAssertEqual(days[0].hrvMs, 48.2)
        XCTAssertEqual(days[0].sleepSeconds, 22320)
        XCTAssertEqual(days[0].tsb!, -16.3, accuracy: 0.01)
        XCTAssertNotNil(days[0].updatedAt)
    }

    func testActivitiesDecodeAndMapTrainerAndFTPFields() async throws {
        let json = #"[{"id":"i9","name":"Umbral","type":"VirtualRide","start_date_local":"2026-10-27T18:05:00","moving_time":3600,"icu_training_load":72,"icu_intensity":84.2,"icu_average_watts":198,"icu_weighted_avg_watts":210,"average_heartrate":152,"icu_ftp":240,"icu_pm_ftp":248,"trainer":true,"external_id":"cadencia-abc"}]"#
        let t = FakeTransport(responses: [HTTPResponse(status: 200, body: Data(json.utf8))])
        let client = IntervalsClient(transport: t, credential: .apiKey("k"))
        let acts = try await client.activities(oldest: Day(year: 2026, month: 10, day: 1), newest: Day(year: 2026, month: 10, day: 28))
        XCTAssertEqual(acts.count, 1)
        XCTAssertEqual(acts[0].day, Day(year: 2026, month: 10, day: 27))
        XCTAssertEqual(acts[0].estimatedFTP, 248)
        XCTAssertTrue(acts[0].isTrainer)
        XCTAssertTrue(acts[0].isCycling)
        XCTAssertEqual(acts[0].externalID, "cadencia-abc")
    }

    func testUploadSendsMultipartWithExternalIDAndReturnsActivityID() async throws {
        let t = FakeTransport(responses: [HTTPResponse(status: 200, body: Data(#"{"icu_athlete_id":"i1","activities":[{"icu_athlete_id":"i1","id":"i777"}]}"#.utf8))])
        let client = IntervalsClient(transport: t, credential: .apiKey("k"))
        let result = try await client.uploadActivity(tcx: Data("<x/>".utf8), name: "Easy", externalID: "cadencia-1", pairedEventID: 42)
        XCTAssertEqual(result.activityID, "i777")
        let req = t.requests[0]
        XCTAssertEqual(req.method, .post)
        XCTAssertEqual(req.url.path, "/api/v1/athlete/0/activities")
        XCTAssertTrue(req.url.query!.contains("external_id=cadencia-1"))
        XCTAssertTrue(req.url.query!.contains("paired_event_id=42"))
        XCTAssertTrue(req.headers["Content-Type"]!.hasPrefix("multipart/form-data; boundary="))
        let body = String(data: req.body!, encoding: .utf8)!
        XCTAssertTrue(body.contains("name=\"file\"; filename=\"cadencia-1.tcx\""))
        XCTAssertTrue(body.contains("<x/>"))
    }

    func testUnauthorizedBecomesTypedError() async {
        let t = FakeTransport(responses: [HTTPResponse(status: 401, body: Data())])
        let client = IntervalsClient(transport: t, credential: .apiKey("bad"))
        do {
            _ = try await client.athlete()
            XCTFail("expected throw")
        } catch let e as HTTPError {
            XCTAssertTrue(e.isAuthFailure)
        } catch {
            XCTFail("wrong error \(error)")
        }
    }

    func testPlannedWorkoutUpsertRendersStructureAndUsesStableUID() async throws {
        let t = FakeTransport(responses: [HTTPResponse(status: 200, body: Data(#"{"id":5,"uid":"cadencia-x","start_date_local":"2026-10-28T00:00:00"}"#.utf8))])
        let client = IntervalsClient(transport: t, credential: .apiKey("k"))
        let workout = Workout(name: "Easy endurance", kind: .endurance, steps: DailyPrescriber.steps(kind: .endurance, minutes: 60), intensityCeiling: 0.69, rationale: "Low HRV")
        let session = PlannedSession(day: Day(year: 2026, month: 10, day: 28), kind: .endurance, title: "Easy endurance", targetMinutes: 60, status: .generated, workout: workout)
        let event = try await client.upsertPlannedWorkout(session, ftp: 240)
        XCTAssertEqual(event.id, 5)
        let req = t.requests[0]
        XCTAssertEqual(req.url.query, "upsertOnUid=true")
        let body = try JSONSerialization.jsonObject(with: req.body!) as! [String: Any]
        XCTAssertEqual(body["uid"] as? String, "cadencia-\(session.id.uuidString.lowercased())")
        XCTAssertEqual(body["start_date_local"] as? String, "2026-10-28T00:00:00")
        XCTAssertEqual(body["moving_time"] as? Int, 3600)
        let description = body["description"] as! String
        XCTAssertTrue(description.contains("- 10m ramp 45-60%"))
        XCTAssertTrue(description.contains("- 45m 65% 88rpm"))
    }
}

final class WorkoutTextTests: XCTestCase {
    func testRendersStepsRampsAndCadence() {
        let w = Workout(name: "T", kind: .threshold, steps: [
            WorkoutStep(name: "Warm-up", duration: 600, startIntensity: 0.45, endIntensity: 0.75),
            WorkoutStep(name: "Threshold 1", duration: 90, intensity: 0.98, cadenceRPM: 90),
        ])
        XCTAssertEqual(WorkoutText.render(w), "Warm-up\n- 10m ramp 45-75%\n\nThreshold 1\n- 1m30s 98% 90rpm")
    }
}

final class OAuthTests: XCTestCase {
    func testPKCEChallengeMatchesRFC7636Vector() {
        // RFC 7636 appendix B: verifier "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk" → challenge "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        let digest = SHA256.hash(Array(verifier.utf8))
        let challenge = Data(digest).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        XCTAssertEqual(challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testSHA256KnownAnswer() {
        let hex = SHA256.hash(Array("abc".utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hex, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let empty = SHA256.hash([]).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(empty, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    func testAuthorizationURLAndExchangeOmitClientSecret() async throws {
        let oauth = IntervalsOAuth(clientID: "cad", redirectURI: "cadencia://oauth")
        let pkce = IntervalsOAuth.makePKCE(randomBytes: Array(repeating: 7, count: 64))
        XCTAssertEqual(pkce.verifier.count, 64)
        let url = oauth.authorizationURL(pkce: pkce, state: "s1")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(items.first { $0.name == "scope" }?.value, "ACTIVITY:WRITE,WELLNESS:READ,CALENDAR:WRITE,SETTINGS:READ")
        XCTAssertEqual(items.first { $0.name == "code_challenge_method" }?.value, "S256")
        XCTAssertEqual(items.first { $0.name == "code_challenge" }?.value, pkce.challenge)

        let t = FakeTransport(responses: [HTTPResponse(status: 200, body: Data(#"{"token_type":"Bearer","access_token":"abc","scope":"ACTIVITY:WRITE,WELLNESS:READ","athlete":{"id":"i1","name":"F"}}"#.utf8))])
        let token = try await oauth.exchange(code: "c0de", pkce: pkce, transport: t)
        XCTAssertEqual(token.access_token, "abc")
        XCTAssertEqual(token.scopes, ["ACTIVITY:WRITE", "WELLNESS:READ"])
        let form = String(data: t.requests[0].body!, encoding: .utf8)!
        XCTAssertTrue(form.contains("code_verifier=\(pkce.verifier)"))
        XCTAssertFalse(form.contains("client_secret"))
    }
}

final class UploadLedgerTests: XCTestCase {
    let ride = UUID()
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testAuthFailureParksEntryUntilSameAthleteReconnects() {
        var ledger = UploadLedger()
        ledger.enqueue(rideID: ride, athleteID: "i1")
        ledger.markAttempt(ride, at: now)
        ledger.markFailure(ride, error: .unauthorized, requestWasSent: true)
        XCTAssertEqual(ledger.entry(for: ride)?.state, .needsReconnect)
        XCTAssertTrue(ledger.due(for: "i1", now: now.addingTimeInterval(99_999)).isEmpty)
        ledger.reconnect(athleteID: "i2")
        XCTAssertEqual(ledger.entry(for: ride)?.state, .needsReconnect, "another athlete's reconnect must not release it")
        ledger.reconnect(athleteID: "i1")
        XCTAssertEqual(ledger.entry(for: ride)?.state, .pending)
    }

    func testTransportFailureAfterSendIsUncertainNotPending() {
        var ledger = UploadLedger()
        ledger.enqueue(rideID: ride, athleteID: "i1")
        ledger.markAttempt(ride, at: now)
        ledger.markFailure(ride, error: .transport("timeout"), requestWasSent: true)
        XCTAssertEqual(ledger.entry(for: ride)?.state, .uncertain)
        ledger.markFailure(ride, error: .status(500, "boom"), requestWasSent: true)
        XCTAssertEqual(ledger.entry(for: ride)?.state, .pending, "a clean 5xx means the server did not store it")
    }

    func testBackoffGrowsWithAttempts() {
        var ledger = UploadLedger()
        ledger.enqueue(rideID: ride, athleteID: "i1")
        XCTAssertTrue(ledger.due(for: "i1", now: now).count == 1)
        ledger.markAttempt(ride, at: now)
        ledger.markFailure(ride, error: .status(502, ""), requestWasSent: true)
        XCTAssertTrue(ledger.due(for: "i1", now: now.addingTimeInterval(10)).isEmpty)
        XCTAssertEqual(ledger.due(for: "i1", now: now.addingTimeInterval(31)).count, 1)
        ledger.markAttempt(ride, at: now.addingTimeInterval(31))
        ledger.markFailure(ride, error: .status(502, ""), requestWasSent: true)
        XCTAssertTrue(ledger.due(for: "i1", now: now.addingTimeInterval(31 + 100)).isEmpty, "second retry waits 120 s")
        XCTAssertEqual(ledger.due(for: "i1", now: now.addingTimeInterval(31 + 121)).count, 1)
        ledger.markConfirmed(ride, activityID: "i9", at: now)
        XCTAssertTrue(ledger.pending(for: "i1").isEmpty)
        XCTAssertEqual(ledger.entry(for: ride)?.intervalsActivityID, "i9")
    }

    func testEnqueueIsIdempotent() {
        var ledger = UploadLedger()
        ledger.enqueue(rideID: ride, athleteID: "i1")
        ledger.enqueue(rideID: ride, athleteID: "i1")
        XCTAssertEqual(ledger.entries.count, 1)
    }
}

final class RideRecordingTests: XCTestCase {
    func makeRide(watts: [Int]) -> RideRecording {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let samples = watts.enumerated().map { RideSample(time: start.addingTimeInterval(Double($0.offset)), watts: $0.element, heartRate: 120 + $0.offset % 3, cadence: 88) }
        return RideRecording(athleteID: "i1", workout: Workout(name: "W", kind: .endurance, steps: []), startedAt: start, endedAt: start.addingTimeInterval(Double(watts.count)), samples: samples)
    }

    func testNormalizedPowerExceedsAverageForVariableEffort() {
        var watts: [Int] = []
        for i in 0..<120 { watts.append(i % 60 < 30 ? 300 : 100) }
        let ride = makeRide(watts: watts)
        XCTAssertEqual(ride.averageWatts, 200)
        XCTAssertGreaterThan(ride.normalizedWatts!, 200)
        XCTAssertEqual(ride.duration, 120)
        XCTAssertEqual(ride.kilojoules, 24, accuracy: 0.001)
    }

    func testSteadyEffortNormalizedEqualsAverage() {
        let ride = makeRide(watts: Array(repeating: 150, count: 90))
        XCTAssertEqual(ride.normalizedWatts, 150)
        XCTAssertEqual(ride.trainingLoad(ftp: 300), 1) // 90 s at IF 0.5 → 0.025 h × 0.25 × 100 ≈ 0.6 → 1
    }

    func testTCXContainsPowerHeartRateAndCadencePerTrackpoint() {
        let ride = makeRide(watts: [150, 160])
        let xml = String(data: TCXEncoder.encode(ride), encoding: .utf8)!
        XCTAssertTrue(xml.contains("<Activity Sport=\"Biking\">"))
        XCTAssertEqual(xml.components(separatedBy: "<Trackpoint>").count - 1, 2)
        XCTAssertTrue(xml.contains("<ns3:Watts>160</ns3:Watts>"))
        XCTAssertTrue(xml.contains("<HeartRateBpm><Value>121</Value></HeartRateBpm>"))
        XCTAssertTrue(xml.contains("<Cadence>88</Cadence>"))
        XCTAssertTrue(xml.contains("<Time>2023-11-14T22:13:20Z</Time>"))
        XCTAssertTrue(xml.contains("<TotalTimeSeconds>2</TotalTimeSeconds>"))
    }
}
