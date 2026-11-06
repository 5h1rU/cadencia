import XCTest
@testable import CadenciaCore

/// Answers like the backend: a receipt for every command, and for each view read whatever `views` holds
/// for its name (`null` otherwise). Records every request.
final class BackendTransport: HTTPTransport, @unchecked Sendable {
    var requests: [HTTPRequest] = []
    var views: [String: [String]] = [:]
    var failures: [HTTPResponse] = []
    var transportErrors = 0
    private let lock = NSLock()

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        try lock.withLock { try answer(request) }
    }

    private func answer(_ request: HTTPRequest) throws -> HTTPResponse {
        requests.append(request)
        if transportErrors > 0 { transportErrors -= 1; throw URLError(.networkConnectionLost) }
        if !failures.isEmpty { return failures.removeFirst() }
        if request.method == .post {
            return HTTPResponse(status: 200, body: Data(#"{"reply":null,"stream":"Plan/i100:p1","version":3}"#.utf8))
        }
        let view = request.url.pathComponents.dropFirst(2).first ?? ""
        if var queue = views[view], !queue.isEmpty {
            let next = queue.count > 1 ? queue.removeFirst() : queue[0]
            views[view] = queue
            return HTTPResponse(status: 200, body: Data(next.utf8))
        }
        return HTTPResponse(status: 200, body: Data("null".utf8))
    }

    /// A command's JSON body, without the per-call `commandId`.
    func body(_ index: Int) throws -> [String: Any] {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(requests[index].body)) as? [String: Any])
        json["commandId"] = nil
        return json
    }

    var commands: [HTTPRequest] { requests.filter { $0.method == .post } }
}

/// The fixtures `web/packages/server/test/IosContract.test.ts` shares: the command bodies this client
/// sends (replayed there through the backend's HTTP API) and the views the backend answers with.
enum BackendFixtures {
    static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
    static var requests: URL { directory.appendingPathComponent("backend-requests.json") }
    static var views: URL { directory.appendingPathComponent("backend-views.json") }

    static func view(_ name: String) throws -> Data {
        let all = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: views)) as? [String: Any])
        return try JSONSerialization.data(withJSONObject: XCTUnwrap(all[name]), options: [.sortedKeys])
    }
}

final class BackendContractTests: XCTestCase {
    let today = Day(year: 2026, month: 11, day: 9)
    let tuesday = Day(year: 2026, month: 11, day: 10)
    let thursday = Day(year: 2026, month: 11, day: 12)

    func draft() -> PlanConsultation.Draft {
        .init(title: "Base block", goal: .endurance, startDay: today, endDay: Day(year: 2026, month: 12, day: 20),
              details: .init(objective: "Build an aerobic base", rationale: "Six weeks of easy volume.",
                             weeklyRides: [.init(weekday: 3, minutes: 60, kind: .endurance),
                                           .init(weekday: 5, minutes: 60, kind: .tempo),
                                           .init(weekday: 1, minutes: 120, kind: .longRide)],
                             otherTraining: [.init(name: "Gym", weekdays: [2], minutes: 45, intensity: .hard)]),
              phases: [.init(focus: .base, startWeek: 1, endWeek: 4, summary: "Aerobic base"),
                       .init(focus: .build, startWeek: 5, endWeek: 5, summary: "Longer tempo"),
                       .init(focus: .recover, startWeek: 6, endWeek: 6, summary: "Absorb")])
    }

    func steady(_ minutes: Double, _ intensity: Double) -> WorkoutStep {
        WorkoutStep(name: "\(Int(intensity * 100))%", duration: minutes * 60, intensity: intensity)
    }

    var easy: Workout { Workout(name: "Easy endurance", kind: .endurance, steps: [steady(60, 0.65)], rationale: "Typical HRV.") }
    var threshold: Workout {
        Workout(name: "Threshold", kind: .threshold, steps: [steady(15, 0.6), steady(30, 0.98), steady(15, 0.55)], intensityCeiling: 1.0)
    }
    let note = CoachNote(headline: "Easy endurance", body: "Ready.", session: "One hour in Z2.")
    let readiness = Readiness(level: .normal, score: 62, signals: [], missingData: [], summary: "Typical HRV and sleep.")

    func evidence(_ fingerprint: String) -> CadenciaAPI.EvidenceSnapshot {
        CoachEvidence.snapshot(fingerprint: fingerprint, readiness: readiness, availability: nil, events: [], from: tuesday)
    }

    func report() -> CyclistProfile.Report {
        .init(riderType: .endurance, confidence: .moderate, headline: "A steady endurance rider",
              summary: "Long, even rides.", strengths: ["Pacing"], development: ["Short power"], evidence: ["20 rides"],
              caveats: [], oldest: Day(year: 2026, month: 8, day: 1), newest: Day(year: 2026, month: 11, day: 8),
              rideCount: 20, model: "gpt-5.5", generatedAt: Date())
    }

    /// Every command the app sends, in the order the contract test replays them, through the real methods.
    func sendContractCommands() async throws -> [(String, [String: Any])] {
        let transport = BackendTransport()
        transport.views = [
            "ConsultationView": [#"{"stage":"created","turns":[],"draft":null,"planId":"i100:p1","refusal":null}"#],
            "TodayDecision": [#"{"athleteId":"i100","day":"2026-11-10","attempt":1,"status":"accepted","workout":null,"note":null,"evidence":null,"model":null,"interpretedOn":null,"refusal":null}"#],
            "ConversationThread": [#"{"messages":[]}"#],
        ]
        let api = CadenciaAPI(baseURL: URL(string: "https://cadencia.example")!, transport: transport, sessionToken: "token")
        let backend = CoachBackend(api: api, athleteId: "i100", pause: { _ in })
        let consultation = "i100:c1", conversation = BackendID.conversation(athlete: "i100", day: tuesday)
        var labels: [String] = []
        func label(_ name: String) { labels.append(name) }

        _ = try await api.startConsultation(consultation, commandId: "start-c1"); label("startConsultation")
        _ = try await backend.recordQuestion("What should your riding feel like?", model: "gpt-5.5", in: consultation); label("recordCoachQuestion")
        _ = try await backend.answer("Six weeks of base, three rides a week.", in: consultation); label("answerQuestion")
        _ = try await backend.recordDraft(try CadenciaAPI.PlanDraft(draft(), athleteId: "i100", today: today), model: "gpt-5.5", in: consultation)
        label("recordDraft")
        _ = try await backend.acceptDraft(planId: "i100:p1", in: consultation); label("acceptDraft")
        _ = try await backend.recordDecision(on: tuesday, planId: "i100:p1", workout: threshold, note: note, evidence: evidence("fp-1"), model: "gpt-5.5")
        label("recordDailyDecisionRefused")
        _ = try await backend.recordDecision(on: tuesday, planId: "i100:p1", workout: easy, note: note, evidence: evidence("fp-1"), model: "gpt-5.5")
        label("recordDailyDecisionAccepted")
        try await backend.sendMessage("Thursday I only have 40 minutes.", messageId: "m1", on: tuesday); label("sendMessage")
        let limit = CadenciaAPI.Intent(CoachIntent(constraints: [.init(day: thursday, maxMinutes: 40)], reply: "I'll shorten Thursday to 40 minutes."),
                                       planId: "i100:p1", today: tuesday)
        _ = try await backend.recordReply("I'll shorten Thursday to 40 minutes.", messageId: "m2", inReplyTo: "m1", intent: limit,
                                          model: "gpt-5.5", on: tuesday); label("recordCoachReplyWithIntent")
        _ = try await backend.acceptIntent(messageId: "m2", in: conversation); label("acceptIntent")
        try await backend.sendMessage("Thanks!", messageId: "m3", on: tuesday); label("sendMessageThanks")
        _ = try await backend.recordReply("You're welcome.", messageId: "m4", inReplyTo: "m3", intent: nil, model: "gpt-5.5", on: tuesday)
        label("recordCoachReplyWithoutIntent")
        try await backend.sendMessage("Saturday I'm away.", messageId: "m5", on: tuesday); label("sendMessageAway")
        let away = CadenciaAPI.Intent(CoachIntent(constraints: [.init(day: Day(year: 2026, month: 11, day: 14), unavailable: true)],
                                                  reply: "Saturday off, then."), planId: "i100:p1", today: tuesday)
        _ = try await backend.recordReply("Saturday off, then.", messageId: "m6", inReplyTo: "m5", intent: away, model: "gpt-5.5", on: tuesday)
        label("recordCoachReplyAway")
        _ = try await backend.dismissIntent(messageId: "m6", in: conversation); label("dismissIntent")
        _ = try await backend.recordProfileAttempt(automatic: true); label("recordProfileAttempt")
        _ = try await backend.recordProfile(report()); label("recordProfile")
        _ = try await backend.recordDayRequirement("Thursday I only have 40 minutes.", maxMinutes: nil, on: thursday, plan: "i100:p1")
        label("recordDayRequirement")
        _ = try await backend.moveSession(thursday.iso, to: thursday.adding(days: 1), plan: "i100:p1"); label("moveSession")
        _ = try await backend.retirePlan("i100:p1"); label("retirePlan")

        let commands = transport.commands
        XCTAssertEqual(commands.count, labels.count)
        return try labels.enumerated().map { index, name in
            let request = commands[index]
            XCTAssertEqual(request.headers["Authorization"], "Bearer token")
            XCTAssertEqual(request.headers["Content-Type"], "application/json")
            var body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.body)) as? [String: Any])
            XCTAssertNotNil(body["commandId"] as? String, name)
            body["commandId"] = nil
            return (name, ["command": request.url.lastPathComponent, "body": body])
        }
    }

    /// The bodies must be byte-for-byte what the backend's contract test replayed. Run with
    /// `CADENCIA_UPDATE_FIXTURES=1 swift test --filter BackendContractTests` after changing what iOS sends,
    /// then run the web contract test.
    func testCommandsMatchTheContractTheBackendReplays() async throws {
        let commands = try await sendContractCommands()
        let current = Dictionary(uniqueKeysWithValues: commands)
        if ProcessInfo.processInfo.environment["CADENCIA_UPDATE_FIXTURES"] != nil {
            let ordered = commands.map(\.0)
            let data = try JSONSerialization.data(withJSONObject: ["order": ordered, "commands": current],
                                                  options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try data.write(to: BackendFixtures.requests)
        }
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: BackendFixtures.requests)) as? [String: Any])
        XCTAssertEqual(saved["order"] as? [String], commands.map(\.0))
        let savedCommands = try XCTUnwrap(saved["commands"] as? [String: Any])
        for (name, command) in commands {
            XCTAssertEqual(savedCommands[name] as? NSDictionary, command as NSDictionary, "\(name) changed; update the fixtures")
        }
    }

    func testRequiredNullFieldsAreSentAsNull() async throws {
        let commands = Dictionary(uniqueKeysWithValues: try await sendContractCommands())
        func input(_ name: String) throws -> [String: Any] {
            let body = try XCTUnwrap((commands[name]?["body"] as? [String: Any]))
            return try XCTUnwrap(body["input"] as? [String: Any])
        }
        let decision = try input("recordDailyDecisionAccepted")
        XCTAssertTrue((decision["note"] as? [String: Any])?["watch"] is NSNull)
        XCTAssertTrue(((decision["evidence"] as? [String: Any])?["days"] as? [[String: Any]])?.first?["maxMinutes"] is NSNull)
        XCTAssertEqual(decision["interpretedOn"] as? String, "ios")
        XCTAssertTrue(try input("recordCoachReplyWithoutIntent")["intent"] is NSNull)
        XCTAssertTrue((try input("recordDraft")["draft"] as? [String: Any])?["event"] is NSNull)
        XCTAssertTrue(try input("recordDayRequirement")["maxMinutes"] is NSNull)
        XCTAssertEqual(try input("startConsultation").count, 0)
        XCTAssertEqual(try input("retirePlan").count, 0)
        // An optional field with no value is left out, as Effect expects.
        let steps = (decision["workout"] as? [String: Any])?["steps"] as? [[String: Any]]
        XCTAssertNil(steps?.first?["cadenceRpm"])
    }

    func testDraftBecomesThePlanSessionsWithTheirPurpose() throws {
        let wire = try CadenciaAPI.PlanDraft(draft(), athleteId: "i100", today: today)
        XCTAssertEqual(wire.athleteId, "i100")
        XCTAssertEqual(wire.goal, .endurance)
        XCTAssertEqual(wire.longRideWeekday, 1)
        XCTAssertEqual(wire.sessions.first?.day, "2026-11-10")
        XCTAssertEqual(wire.sessions.first?.kind, .endurance)
        XCTAssertEqual(wire.sessions.first?.purpose, "Aerobic base")
        // The day after hard gym stays easy; Thursday keeps its tempo.
        XCTAssertEqual(wire.sessions.first { $0.day == "2026-11-12" }?.kind, .tempo)
        XCTAssertEqual(wire.phases.map(\.focus), [.base, .build, .recover])
        XCTAssertNil(wire.event)
    }

    func testCoachIntentBecomesDayLimitsOnlyWhenItChangesThePlan() {
        let request = CoachIntent(constraints: [.init(day: thursday, maxMinutes: 40), .init(day: today.adding(days: -1), maxMinutes: 10)],
                                  reply: "Shorter Thursday", workoutRequest: .init(day: Day(year: 2026, month: 11, day: 13), instructions: "Intervals"))
        let intent = CadenciaAPI.Intent(request, planId: "i100:p1", today: today)
        XCTAssertEqual(intent?.limits.map(\.day), ["2026-11-12", "2026-11-13"])
        XCTAssertEqual(intent?.limits.first?.maxMinutes, 40)
        XCTAssertEqual(intent?.limits.last?.maxMinutes, nil)
        XCTAssertNil(CadenciaAPI.Intent(CoachIntent(reply: "Hi"), planId: "i100:p1", today: today))
        XCTAssertNil(CadenciaAPI.Intent(CoachIntent(constraints: [.init(day: thursday, unavailable: true)], needsClarification: ["Which?"]),
                                        planId: "i100:p1", today: today))
    }

    func testEvidenceReadsEachDayFromIntervals() throws {
        let availability = [IntervalsAvailabilityDay(dayOfWeek: 2, level: .limited, maxTrainingSeconds: 2700),
                            IntervalsAvailabilityDay(dayOfWeek: 4, level: .unavailable)]
        func event(_ id: Int, _ category: String, _ day: String, end: String? = nil, tags: [String]? = nil) throws -> IntervalsEvent {
            var json: [String: Any] = ["id": id, "category": category, "start_date_local": day + "T00:00:00"]
            if let end { json["end_date_local"] = end + "T00:00:00" }
            if let tags { json["tags"] = tags }
            return try JSONDecoder().decode(IntervalsEvent.self, from: JSONSerialization.data(withJSONObject: json))
        }
        let events = [try event(1, "HOLIDAY", "2026-11-13", end: "2026-11-14"),
                      try event(2, "WORKOUT", "2026-11-15", tags: ["intensity-hard"]),
                      try event(3, "RACE_A", "2026-11-22")]
        let snapshot = CoachEvidence.snapshot(fingerprint: "fp", readiness: readiness, availability: availability, events: events, from: tuesday)
        let byDay = Dictionary(uniqueKeysWithValues: snapshot.days.map { ($0.day, $0) })
        XCTAssertEqual(snapshot.days.count, 8)
        XCTAssertEqual(byDay["2026-11-10"]?.maxMinutes, 45) // Tuesday is ISO day 2
        XCTAssertEqual(byDay["2026-11-12"]?.unavailable, true) // Thursday, ISO 4
        XCTAssertEqual(byDay["2026-11-14"]?.unavailable, true) // holiday's last day
        XCTAssertEqual(byDay["2026-11-15"]?.hardOtherTraining, true)
        XCTAssertEqual(byDay["2026-11-16"]?.hardOtherTraining, true) // the day after
        XCTAssertEqual(byDay["2026-11-17"]?.hardOtherTraining, false)
        XCTAssertEqual(snapshot.eventDays, ["2026-11-22"])
        XCTAssertEqual(snapshot.readiness.level, .normal)
    }

    // MARK: Views, as the backend answered them in the contract test

    func testCurrentPlanBecomesTheAppsPlan() throws {
        let view = try JSONDecoder().decode(CadenciaAPI.CurrentPlanState.self, from: BackendFixtures.view("plan"))
        let context = PlanContext(planId: "i100:p1", availability: Availability(hoursPerWeek: 4, minutesByWeekday: [3: 60, 5: 60, 1: 120], longRideWeekday: 1),
                                  details: draft().details)
        let plan = try XCTUnwrap(TrainingPlan(view, context: context))
        XCTAssertEqual(plan.backendID, "i100:p1")
        XCTAssertTrue(plan.isActive)
        XCTAssertEqual(plan.title, "Base block")
        XCTAssertEqual(plan.consultation, draft().details)
        XCTAssertEqual(plan.availability.minutesByWeekday[5], 60)
        let tuesday = try XCTUnwrap(plan.sessions.first { $0.day == self.tuesday })
        XCTAssertEqual(tuesday.status, .generated)
        XCTAssertEqual(tuesday.workout?.name, "Easy endurance")
        XCTAssertEqual(tuesday.externalID, "cadencia-i100-p1-2026-11-10")
        XCTAssertEqual(PlanMirror.externalID(for: tuesday), "cadencia-i100-p1-2026-11-10")
        XCTAssertEqual(plan.sessions.first { $0.day == self.thursday }?.status, .provisional)
        XCTAssertEqual(plan.sessions.first { $0.day == self.thursday }?.targetMinutes, 40)
        // Read twice, the plan is the same plan to the views and the ride engine.
        XCTAssertEqual(TrainingPlan(view, context: context), plan)
        // Another plan's context is not applied.
        XCTAssertNil(TrainingPlan(view, context: PlanContext(planId: "i100:p0", details: draft().details))?.consultation)
    }

    func testRetiredPlanAndChangesNeedingNoAI() throws {
        let changed = try JSONDecoder().decode(CadenciaAPI.CurrentPlanState.self, from: BackendFixtures.view("planChanged"))
        XCTAssertEqual(changed.requirements.first?.day, "2026-11-12")
        XCTAssertNil(changed.requirements.first?.maxMinutes)
        XCTAssertTrue(changed.sessions.contains { $0.sessionId == "2026-11-12" && $0.day == "2026-11-13" })
        let retired = try JSONDecoder().decode(CadenciaAPI.CurrentPlanState.self, from: BackendFixtures.view("planRetired"))
        XCTAssertEqual(retired.status, .retired)
        XCTAssertEqual(TrainingPlan(retired, context: nil)?.isActive, false)
        XCTAssertNil(try JSONDecoder().decode(CadenciaAPI.CurrentPlanState?.self, from: Data("null".utf8)))
    }

    func testDecisionsCarryTheVerdict() throws {
        let refused = try JSONDecoder().decode(CadenciaAPI.TodayDecisionState.self, from: BackendFixtures.view("decisionRefused"))
        XCTAssertEqual(refused.status, .refused)
        XCTAssertTrue(refused.refusal?.contains("HardensPlannedSession") == true)
        let accepted = try JSONDecoder().decode(CadenciaAPI.TodayDecisionState.self, from: BackendFixtures.view("decisionAccepted"))
        XCTAssertEqual(accepted.status, .accepted)
        XCTAssertEqual(accepted.attempt, 2)
        XCTAssertEqual(accepted.interpretedOn, .ios)
        let workout = Workout(try XCTUnwrap(accepted.workout), identity: "i100:2026-11-10#2")
        XCTAssertEqual(workout.name, "Easy endurance")
        XCTAssertEqual(workout.totalDuration, 3600)
        XCTAssertEqual(workout.id, Workout(accepted.workout!, identity: "i100:2026-11-10#2").id)
        XCTAssertEqual(CoachNote(try XCTUnwrap(accepted.note)), note)
        XCTAssertEqual(accepted.evidence?.fingerprint, "fp-1")
    }

    func testThreadShowsEachIntentAndWhereItStands() throws {
        let thread = try JSONDecoder().decode(CadenciaAPI.ConversationThreadState.self, from: BackendFixtures.view("thread"))
        XCTAssertEqual(thread.messages.map(\.messageId), ["m1", "m2", "m3", "m4", "m5", "m6"])
        XCTAssertEqual(thread.messages[1].role, .coach)
        XCTAssertEqual(thread.messages[1].intent?.limits.first?.maxMinutes, 40)
        XCTAssertEqual(thread.messages[1].intentStatus, .applied)
        XCTAssertNil(thread.messages[3].intent)
        XCTAssertEqual(thread.messages[5].intentStatus, .dismissed)
        XCTAssertEqual(thread.messages[1].model, "gpt-5.5")
    }

    func testConsultationAndProfileCard() throws {
        let consultation = try JSONDecoder().decode(CadenciaAPI.ConsultationViewState.self, from: BackendFixtures.view("consultation"))
        XCTAssertEqual(consultation.stage, .created)
        XCTAssertEqual(consultation.planId, "i100:p1")
        XCTAssertEqual(consultation.turns.map(\.role), [.coach, .athlete])
        XCTAssertEqual(consultation.draft?.title, "Base block")
        let card = try JSONDecoder().decode(CadenciaAPI.RiderProfileCardState.self, from: BackendFixtures.view("profile"))
        let profile = try XCTUnwrap(CyclistProfile.Report(card))
        XCTAssertEqual(profile.riderType, .endurance)
        XCTAssertEqual(profile.model, "gpt-5.5")
        XCTAssertEqual(profile.rideCount, 20)
        XCTAssertEqual(profile.generatedAt, Day(year: 2026, month: 11, day: 8).date())
    }
}

final class CadenciaAPITests: XCTestCase {
    let base = URL(string: "https://cadencia.example")!

    func testSignInStartsOnTheServerAndTheHandoffIsExchanged() async throws {
        let api = CadenciaAPI(baseURL: base, transport: FakeTransport())
        XCTAssertEqual(api.signInURL.absoluteString, "https://cadencia.example/auth/intervals/start?client=ios")
        XCTAssertEqual(CadenciaAPI.handoff(from: URL(string: "cadencia://auth/callback?handoff=abc.def")!), "abc.def")
        XCTAssertNil(CadenciaAPI.handoff(from: URL(string: "cadencia://oauth?code=1")!))
        XCTAssertNil(CadenciaAPI.handoff(from: URL(string: "cadencia://auth/callback")!))

        let transport = FakeTransport(responses: [.init(status: 200, body: Data(#"{"token":"session-token"}"#.utf8)),
                                                  .init(status: 200, body: Data(#"{"athleteId":"i100"}"#.utf8))])
        var client = CadenciaAPI(baseURL: base, transport: transport)
        let token = try await client.exchange(handoff: "abc.def")
        XCTAssertEqual(token, "session-token")
        XCTAssertEqual(transport.requests[0].url.absoluteString, "https://cadencia.example/auth/exchange")
        XCTAssertEqual(String(decoding: transport.requests[0].body!, as: UTF8.self), #"{"handoff":"abc.def"}"#)
        client.sessionToken = token
        let athlete = try await client.signedInAthlete()
        XCTAssertEqual(athlete, "i100")
        XCTAssertEqual(transport.requests[1].headers["Authorization"], "Bearer session-token")

        let expired = FakeTransport(responses: [.init(status: 401, body: Data())])
        do {
            _ = try await CadenciaAPI(baseURL: base, transport: expired).exchange(handoff: "old")
            XCTFail("An expired handoff must not sign in")
        } catch let error as CadenciaAPIError { XCTAssertEqual(error, .signedOut) }
    }

    func testReadsWaitForTheirWriteAndKeepTheIdsColon() async throws {
        let transport = BackendTransport()
        let api = CadenciaAPI(baseURL: base, transport: transport, sessionToken: "t")
        let receipt = CadenciaAPI.Receipt(stream: "DailyDecision/i100:2026-11-10", version: 4)
        let state = try await api.getTodayDecision("i100:2026-11-10", after: receipt)
        XCTAssertNil(state)
        let url = try XCTUnwrap(transport.requests.first?.url)
        XCTAssertEqual(url.path, "/v1/TodayDecision/i100:2026-11-10")
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query, [URLQueryItem(name: "stream", value: "DailyDecision/i100:2026-11-10"), URLQueryItem(name: "version", value: "4")])
        XCTAssertEqual(transport.requests.first?.method, .get)
    }

    func testRejectionsKeepTheirTagAndAMissingSessionSignsOut() async throws {
        func failure(_ status: Int, _ body: String) async -> CadenciaAPIError? {
            let transport = BackendTransport()
            transport.failures = [.init(status: status, body: Data(body.utf8))]
            do {
                _ = try await CadenciaAPI(baseURL: base, transport: transport).retirePlan("i100:p1")
                return nil
            } catch { return error as? CadenciaAPIError }
        }
        let refused = await failure(409, #"{"_tag":"PlanNotActive"}"#)
        XCTAssertEqual(refused?.rejection, "PlanNotActive")
        let signedOut = await failure(422, #"{"_tag":"Unauthorized"}"#)
        XCTAssertEqual(signedOut, .signedOut)
        if case .invalidRequest = await failure(400, "Expected a string") {} else { XCTFail("A malformed request is a 400") }
        if case .server(503, _) = await failure(503, "busy") {} else { XCTFail("Server faults keep their status") }
    }
}

final class CoachBackendTests: XCTestCase {
    func backend(_ transport: BackendTransport) -> CoachBackend {
        CoachBackend(api: CadenciaAPI(baseURL: URL(string: "https://cadencia.example")!, transport: transport, sessionToken: "t"),
                     athleteId: "i100", pollInterval: .milliseconds(1), answerTimeout: .milliseconds(5), pause: { _ in })
    }

    let day = Day(year: 2026, month: 11, day: 10)
    func decision(_ status: String, attempt: Int = 1, refusal: String? = nil) -> String {
        let reason = refusal.map { "\"\($0)\"" } ?? "null"
        return #"{"athleteId":"i100","day":"2026-11-10","attempt":\#(attempt),"status":"\#(status)","workout":null,"note":null,"evidence":null,"model":"gpt-5.5","interpretedOn":"ios","refusal":\#(reason)}"#
    }
    let evidence = CadenciaAPI.EvidenceSnapshot(fingerprint: "fp", readiness: .init(level: .normal, score: 60, summary: ""), days: [], eventDays: [])
    let workout = Workout(name: "Easy", kind: .endurance, steps: [WorkoutStep(name: "Z2", duration: 3600, intensity: 0.65)])

    func testDecisionWaitsForThePlansVerdict() async throws {
        let transport = BackendTransport()
        transport.views["TodayDecision"] = [decision("pending"), decision("pending"), decision("refused", refusal: "HardensPlannedSession")]
        let verdict = try await backend(transport).recordDecision(on: day, planId: "i100:p1", workout: workout,
                                                                  note: .init(headline: "", body: "", session: ""), evidence: evidence, model: "gpt-5.5")
        XCTAssertEqual(verdict.status, .refused)
        XCTAssertEqual(verdict.refusal, "HardensPlannedSession")
        let reads = transport.requests.filter { $0.method == .get }
        XCTAssertEqual(reads.count, 3)
        XCTAssertNotNil(reads[0].url.query, "the first read waits for the write")
        XCTAssertNil(reads[1].url.query)
        XCTAssertEqual(transport.commands.first?.url.path, "/v1/RecordDailyDecision")
        XCTAssertEqual((try transport.body(0))["target"] as? String, "i100:2026-11-10")
    }

    func testAnUnansweredDecisionComesBackPending() async throws {
        let transport = BackendTransport()
        transport.views["TodayDecision"] = [decision("pending")]
        let verdict = try await backend(transport).recordDecision(on: day, planId: "i100:p1", workout: workout,
                                                                  note: .init(headline: "", body: "", session: ""), evidence: evidence, model: "m")
        XCTAssertEqual(verdict.status, .pending)
    }

    func testADroppedConnectionIsRetriedWithTheSameCommandID() async throws {
        let transport = BackendTransport()
        transport.transportErrors = 1
        try await backend(transport).sendMessage("Hi", messageId: "m1", on: day)
        XCTAssertEqual(transport.commands.count, 2)
        let ids = try transport.commands.map { try XCTUnwrap(JSONSerialization.jsonObject(with: $0.body!) as? [String: Any])["commandId"] as? String }
        XCTAssertNotNil(ids[0])
        XCTAssertEqual(ids[0], ids[1])
        XCTAssertEqual((try transport.body(0))["target"] as? String, "i100:2026-11")
    }

    func testASpentAutomaticProfileAttemptIsNotAnError() async throws {
        let transport = BackendTransport()
        transport.failures = [.init(status: 409, body: Data(#"{"_tag":"AutomaticAttemptUsed"}"#.utf8))]
        let allowed = try await backend(transport).recordProfileAttempt(automatic: true)
        XCTAssertFalse(allowed)
        let again = try await backend(transport).recordProfileAttempt(automatic: false)
        XCTAssertTrue(again)
    }

    func testNewIdsBelongToTheAthleteAndHaveNoColonInTheKey() {
        let id = BackendID.new(athlete: "i100", prefix: "c", now: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertTrue(id.hasPrefix("i100:c1800000000"))
        XCTAssertEqual(id.filter { $0 == ":" }.count, 1)
        XCTAssertEqual(BackendID.owner(of: id), "i100")
        XCTAssertEqual(BackendID.conversation(athlete: "i100", day: Day(year: 2026, month: 3, day: 9)), "i100:2026-03")
        XCTAssertEqual(StableID.uuid("a"), StableID.uuid("a"))
        XCTAssertNotEqual(StableID.uuid("a"), StableID.uuid("b"))
    }
}

final class PlanAnswerTests: XCTestCase {
    func backend(_ transport: BackendTransport) -> CoachBackend {
        CoachBackend(api: CadenciaAPI(baseURL: URL(string: "https://cadencia.example")!, transport: transport, sessionToken: "t"),
                     athleteId: "i100", pollInterval: .milliseconds(1), answerTimeout: .milliseconds(5), pause: { _ in })
    }

    func testARefusedDraftReopensTheConsultationWithTheReason() async throws {
        let transport = BackendTransport()
        transport.views["ConsultationView"] = [
            #"{"stage":"accepted","turns":[],"draft":null,"planId":"i100:p1","refusal":null}"#,
            #"{"stage":"open","turns":[],"draft":null,"planId":null,"refusal":"InvalidPlan: reason=\"A plan needs at least one session.\""}"#,
        ]
        let answer = try await backend(transport).acceptDraft(planId: "i100:p1", in: "i100:c1")
        XCTAssertEqual(answer?.stage, .open)
        XCTAssertTrue(answer?.refusal?.hasPrefix("InvalidPlan") == true)
    }

    func testANewPlanIsReadOnceTheViewShowsIt() async throws {
        let transport = BackendTransport()
        func plan(_ id: String) -> String {
            #"{"planId":"\#(id)","status":"active","title":"","goal":null,"startDay":null,"endDay":null,"phases":[],"longRideWeekday":null,"event":null,"sessions":[],"requirements":[]}"#
        }
        transport.views["CurrentPlan"] = [plan("i100:p0"), plan("i100:p0"), plan("i100:p1")]
        let shown = try await backend(transport).plan(showing: "i100:p1")
        XCTAssertEqual(shown?.planId, "i100:p1")
        XCTAssertEqual(transport.requests.count, 3)
    }
}
