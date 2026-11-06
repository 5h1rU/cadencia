import XCTest
@testable import CadenciaCore

final class SessionIntentTests: XCTestCase {
    private let day = Day(year: 2028, month: 3, day: 17)

    private func brief(ftp: Int = 250, eventOffset: Int? = 1) -> CoachBrief {
        let event = eventOffset.map { TrainingEvent(name: "Confirmed event", day: day.adding(days: $0), priority: .b, isRace: false) }
        return CoachBrief(today: day, locale: "en", athlete: .init(ftp: ftp), ftpEstimate: nil, powerCurve: [],
                          wellness: [], feedback: [:], activities: [], plan: nil, upcomingEvent: event,
                          availableMinutes: 60, recentCoachNotes: [],
                          measured: .init(level: .normal, score: 60, signals: [], missingData: ["hrv"], summary: ""))
    }

    private func opener(work: Double = 1.12, workSeconds: Double = 45, recoverySeconds: Double = 120) -> Workout {
        var steps = [WorkoutStep(name: "Warm-up", duration: 600, startIntensity: 0.4, endIntensity: 0.65)]
        for _ in 0..<3 {
            steps.append(.init(name: "Activation", duration: workSeconds, intensity: work))
            steps.append(.init(name: "Easy", duration: recoverySeconds, intensity: 0.5))
        }
        steps.append(.init(name: "Cool-down", duration: 480, startIntensity: 0.55, endIntensity: 0.35))
        return Workout(name: "Event activation", kind: .openerActivation, steps: steps, intensityCeiling: work)
    }

    private func answer(_ workout: Workout) throws -> String {
        let steps: [[String: Any]] = workout.steps.map {
            ["name": $0.name, "minutes": $0.duration / 60, "from": $0.startIntensity, "to": $0.endIntensity]
        }
        let wire: [String: Any] = ["readiness": ["level": "normal", "score": 60],
                                   "workout": ["name": workout.name, "kind": workout.kind.rawValue,
                                               "ceiling": workout.intensityCeiling ?? 1.2, "steps": steps]]
        return String(decoding: try JSONSerialization.data(withJSONObject: wire), as: UTF8.self)
    }

    private func response(_ content: String) throws -> HTTPResponse {
        .init(status: 200, body: try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]]))
    }

    /// Whether a session fits the plan is Planning's to decide on the backend; its refusal reaches the model.
    func testPlanRefusalIsGivenToTheModelForACorrectedDecision() async throws {
        let transport = FakeTransport(responses: [try response(answer(opener()))])
        let coach = LLMCoach(transport: transport, endpoint: URL(string: "https://example.invalid/chat")!, apiKey: "test")
        let result = try await coach.prescribe(brief: brief(), refusal: "HardensPlannedSession: planned=\"endurance\"")
        XCTAssertEqual(result.workout.kind, .openerActivation)
        XCTAssertEqual(transport.requests.count, 1)
        let request = String(decoding: transport.requests[0].body!, as: UTF8.self)
        XCTAssertTrue(request.contains("refused your previous decision"))
        XCTAssertTrue(request.contains("HardensPlannedSession"))
    }

    func testFirstAskCarriesNoRefusal() async throws {
        let transport = FakeTransport(responses: [try response(answer(opener()))])
        let coach = LLMCoach(transport: transport, endpoint: URL(string: "https://example.invalid/chat")!, apiKey: "test")
        _ = try await coach.prescribe(brief: brief())
        XCTAssertFalse(String(decoding: transport.requests[0].body!, as: UTF8.self).contains("refused"))
    }

    func testChatPreservesArbitraryWorkoutRequirementsAsAnAction() async throws {
        let json = """
        {"constraints":[{"day":"\(day.iso)","maxMinutes":50}],
         "workoutRequest":{"day":"\(day.iso)","instructions":"Make the endurance main block 65% FTP, with a gradual warm-up and cool-down."},
         "reply":"Review this proposed endurance session.","needsClarification":[]}
        """
        let transport = FakeTransport(responses: [try response(json)])
        let coach = LLMCoach(transport: transport, endpoint: URL(string: "https://example.invalid/chat")!, apiKey: "test")
        let context = CoachContext(today: day, workout: opener(), recentConversation: ["athlete: Make it endurance instead"])
        let intent = try await coach.interpret("Use 65% for the main block", context: context)
        XCTAssertEqual(intent.workoutRequest?.day, day)
        XCTAssertEqual(intent.workoutRequest?.maxMinutes, 50)
        XCTAssertTrue(intent.workoutRequest!.instructions.contains("65%"))
        XCTAssertFalse(intent.isEmpty)
        let request = String(decoding: transport.requests[0].body!, as: UTF8.self)
        XCTAssertTrue(request.contains("Current workout"))
        XCTAssertTrue(request.contains("Make it endurance instead"))
    }

    func testUnresolvedChatRequestIsNotAnExecutableActionAndLegacyIntentStillDecodes() async throws {
        let json = """
        {"workoutRequest":{"day":"\(day.iso)","instructions":"Unresolved change"},"reply":"Which day?","needsClarification":["Which day?"]}
        """
        let transport = FakeTransport(responses: [try response(json)])
        let coach = LLMCoach(transport: transport, endpoint: URL(string: "https://example.invalid/chat")!, apiKey: "test")
        let intent = try await coach.interpret("Change it", context: .init(today: day))
        XCTAssertNil(intent.workoutRequest)
        let legacy = Data(#"{"constraints":[],"reply":"No change","needsClarification":[]}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(CoachIntent.self, from: legacy).workoutRequest)
    }

    func testDatedRequestsAndPolicyRevisionInvalidateSavedDecisions() throws {
        let base = brief()
        var requested = base
        requested.workoutRequest = .init(day: day, instructions: "Use shorter efforts", maxMinutes: 40)
        XCTAssertNotEqual(base.fingerprint, requested.fingerprint)
        requested.workoutRequest?.instructions = "Use longer easy recoveries"
        let second = requested.fingerprint
        requested.workoutRequest?.maxMinutes = 50
        XCTAssertNotEqual(second, requested.fingerprint)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let oldFingerprint = SHA256.hash(Array(try encoder.encode(base))).map { String(format: "%02x", $0) }.joined()
        XCTAssertNotEqual(base.fingerprint, oldFingerprint)
    }

    func testLateStartingPlansKeepEventAndEveryAvailableDayAcrossWeekBoundaries() {
        for offset in 0..<7 {
            let start = day.adding(days: offset)
            for length in [1, 7, 8, 13, 14] {
                let end = start.adding(days: length)
                let event = TrainingEvent(name: "Event", day: end, priority: .a, isRace: true)
                let availability = Availability(hoursPerWeek: 7, minutesByWeekday: Dictionary(uniqueKeysWithValues: (1...7).map { ($0, 60) }), longRideWeekday: 1)
                let plan = PlanBuilder().build(.init(goal: .event, startDay: start, endDay: end, event: event, availability: availability))
                XCTAssertEqual(plan.sessions.map(\.day), (0...length).map { start.adding(days: $0) })
                XCTAssertEqual(plan.sessions.last?.kind, .race)
                XCTAssertEqual(plan.phase(for: end)?.focus, .taper)
                XCTAssertEqual(plan.sessions.first { $0.day == end.adding(days: -1) }?.kind, .openerActivation)
                XCTAssertEqual(plan.weekCount, plan.weekNumber(of: end))
            }
        }
    }
}
