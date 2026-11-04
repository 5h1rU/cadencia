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

    private func prescription(_ workout: Workout, level: Readiness.Level = .normal) -> DailyPrescription {
        .init(readiness: .init(level: level, score: 60, signals: [], missingData: [], summary: ""), workout: workout,
              week: [], note: .init(headline: "", body: "", session: ""), flags: [], model: "test")
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

    func testActivationIsRelativeToEachAthletesFTPAndAllowsDifferentProtocols() throws {
        for ftp in [140, 265, 390] {
            for intensity in [0.95, 1.05, 1.3] {
                let workout = opener(work: intensity)
                try PrescriptionValidator().validate(prescription(workout), brief: brief(ftp: ftp))
                XCTAssertEqual(workout.targetWatts(ftp: ftp, at: 600), Int((Double(ftp) * intensity).rounded()))
            }
        }
    }

    func testEasyOnlyRideCannotBeMislabeledAsOpener() {
        for intensity in [0.5, 0.75, 0.85] {
            XCTAssertThrowsError(try PrescriptionValidator().validate(prescription(opener(work: intensity)), brief: brief()))
        }
    }

    func testRecoveryCanDowngradeAnOpenerWithoutForcingIntensity() throws {
        let alternative = Workout(name: "Recovery instead of activation", kind: .recovery,
                                  steps: [.init(name: "Easy", duration: 1200, intensity: 0.5)], intensityCeiling: 0.55)
        for level in [Readiness.Level.easy, .rest] {
            try PrescriptionValidator().validate(prescription(alternative, level: level), brief: brief())
        }
    }

    func testOpenerNeedsConfirmedEventOnFollowingDayRegardlessOfPriorityOrRaceType() throws {
        try PrescriptionValidator().validate(prescription(opener()), brief: brief())
        for offset: Int? in [nil, -1, 0, 2, 14] {
            XCTAssertThrowsError(try PrescriptionValidator().validate(prescription(opener()), brief: brief(eventOffset: offset)))
        }
        var planned = brief(eventOffset: nil)
        let event = TrainingEvent(name: "Planned race", day: day.adding(days: 1), priority: .a, isRace: true)
        let plan = PlanBuilder().build(.init(goal: .event, startDay: day, endDay: event.day, event: event, availability: .typical))
        planned.plan = .init(plan, today: day)
        try PrescriptionValidator().validate(prescription(opener()), brief: planned)
    }

    func testLongOrDenseWorkAndIncompleteRecoveryAreRejected() {
        let validator = PrescriptionValidator()
        XCTAssertThrowsError(try validator.validate(prescription(opener(workSeconds: 240, recoverySeconds: 300)), brief: brief()))
        XCTAssertThrowsError(try validator.validate(prescription(opener(workSeconds: 180, recoverySeconds: 180)), brief: brief()))
        XCTAssertThrowsError(try validator.validate(prescription(opener(workSeconds: 60, recoverySeconds: 30)), brief: brief()))
        var noFinalRecovery = opener()
        noFinalRecovery.steps.removeLast(2)
        XCTAssertThrowsError(try validator.validate(prescription(noFinalRecovery), brief: brief()))
    }

    func testSplittingAnEffortIntoStepsCannotBypassContinuousLimit() {
        var workout = opener()
        workout.steps = [.init(name: "Warm-up", duration: 1800, intensity: 0.5)]
            + (0..<4).map { _ in WorkoutStep(name: "Split activation", duration: 60, intensity: 1.1) }
            + [.init(name: "Recovery", duration: 1800, intensity: 0.5)]
        XCTAssertThrowsError(try PrescriptionValidator().validate(prescription(workout), brief: brief()))
    }

    func testTempoDominatedRideAndActivationWithoutWarmupAreNotOpeners() {
        var workout = opener()
        workout.steps[0] = .init(name: "Sustained tempo", duration: 1800, intensity: 0.85)
        XCTAssertThrowsError(try PrescriptionValidator().validate(prescription(workout), brief: brief()))
        workout = opener()
        workout.steps.removeFirst()
        XCTAssertThrowsError(try PrescriptionValidator().validate(prescription(workout), brief: brief()))
    }

    func testZeroCeilingCannotSilenceRidingTargets() throws {
        let json = #"{"readiness":{"level":"normal"},"workout":{"name":"Ride","kind":"endurance","ceiling":0,"steps":[{"name":"Main","minutes":30,"intensity":0.65}]}}"#
        XCTAssertThrowsError(try DailyPrescription.parse(Data(json.utf8), measured: brief().measured, today: day,
                                                        availableMinutes: 60, model: "test"))
    }

    func testRampsCountOnlyTheActualTimeInActivationAndRecoveryZones() throws {
        var workout = opener()
        workout.steps = [.init(name: "Warm-up", duration: 1200, intensity: 0.5),
                         .init(name: "Ramp activation", duration: 300, startIntensity: 0.8, endIntensity: 1.0),
                         .init(name: "Recovery", duration: 300, intensity: 0.5)]
        try PrescriptionValidator().validate(prescription(workout), brief: brief())
        workout.steps[1].duration = 600
        XCTAssertThrowsError(try PrescriptionValidator().validate(prescription(workout), brief: brief()))
    }

    func testWeekMustAgreeWithConcreteWorkout() {
        var p = prescription(opener())
        p.week = [.init(day: day, kind: .endurance, minutes: 30, title: "Different purpose")]
        XCTAssertThrowsError(try PrescriptionValidator().validate(p, brief: brief()))
    }

    func testInvalidPurposeIsCorrectedOnceBeforeReturningExecutableWorkout() async throws {
        let transport = FakeTransport(responses: [try response(answer(opener(work: 0.75))), try response(answer(opener()))])
        let coach = LLMCoach(transport: transport, endpoint: URL(string: "https://example.invalid/chat")!, apiKey: "test")
        let result = try await coach.prescribe(brief: brief())
        XCTAssertEqual(result.workout.steps[1].startIntensity, 1.12)
        XCTAssertEqual(transport.requests.count, 2)
        let correction = String(decoding: transport.requests[1].body!, as: UTF8.self)
        XCTAssertTrue(correction.contains("failed session validation"))
    }

    func testRepeatedInvalidOpenerFailsWithoutReturningPartialDecision() async throws {
        let bad = try response(answer(opener(work: 0.75)))
        let transport = FakeTransport(responses: [bad, bad])
        let coach = LLMCoach(transport: transport, endpoint: URL(string: "https://example.invalid/chat")!, apiKey: "test")
        do {
            _ = try await coach.prescribe(brief: brief())
            XCTFail("Both invalid prescriptions must be rejected")
        } catch let error as DailyPrescription.ValidationError {
            guard case .sessionIntent = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(transport.requests.count, 2)
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
