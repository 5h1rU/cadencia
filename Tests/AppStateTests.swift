import XCTest
import CadenciaCore

final class CoachStateTests: XCTestCase {
    let day = Day(year: 2028, month: 3, day: 17)
    let readiness = Readiness(level: .normal, score: 60, signals: [], missingData: [], summary: "")
    let note = CoachNote(headline: "Endurance", body: "Recovered", session: "Your requested steady ride")

    var workout: Workout {
        Workout(name: "Requested endurance", kind: .endurance, steps: [.init(name: "Main block", duration: 2400, intensity: 0.65)],
                intensityCeiling: 0.75, createdAt: day.date())
    }

    func take(_ state: inout AppState, ftp: Int = 265) {
        state.takeDecision(workout: workout, readiness: readiness, note: note, model: "test", day: day, ftp: ftp)
    }

    /// The plan as the backend's `CurrentPlan` view answers it: one session a day for a week.
    func view(planId: String = "i1:p1", status: CadenciaAPI.CurrentPlanState.Status = .active) -> CadenciaAPI.CurrentPlanState {
        CadenciaAPI.CurrentPlanState(
            planId: planId, status: status, title: "Base", goal: .endurance, startDay: day.iso, endDay: day.adding(days: 6).iso,
            phases: [.init(focus: .base, startWeek: 1, endWeek: 1, summary: "Base")], longRideWeekday: 1, event: nil,
            sessions: (0..<7).map { offset in
                let d = day.adding(days: offset).iso
                return .init(sessionId: d, day: d, kind: .endurance, title: "Endurance", targetMinutes: 60, purpose: "Base",
                             status: .published, externalId: "cadencia-i1-p1-\(d)")
            },
            requirements: [.init(day: day.adding(days: 2).iso, instructions: "Only 40 minutes", maxMinutes: 40)])
    }

    func testDecisionUpdatesThePlanSessionInPlace() {
        var state = AppState()
        state.adoptBackendPlan(view())
        let before = state.plan!
        take(&state)
        XCTAssertEqual(state.plan?.sessions[0].id, before.sessions[0].id)
        XCTAssertEqual(state.plan?.sessions[0].workout, state.today?.workout)
        XCTAssertEqual(state.plan?.sessions[0].prescriptionFTP, 265)
        XCTAssertEqual(state.today?.note, note)
        XCTAssertEqual(state.today?.model, "test")
        XCTAssertEqual(Array(state.plan!.sessions.dropFirst()), Array(before.sessions.dropFirst()))
        XCTAssertNil(state.standaloneSessions)
    }

    func testStandaloneUpdatesReuseIdentityAndCompletedSessionsCannotBeReplaced() {
        var state = AppState()
        take(&state)
        let id = state.standaloneSessions![0].id
        take(&state)
        XCTAssertEqual(state.standaloneSessions?.count, 1)
        XCTAssertEqual(state.standaloneSessions?[0].id, id)
        state.today?.completedRideID = UUID()
        let completed = state
        take(&state)
        XCTAssertEqual(state, completed)
    }

    func testThePlanIsTheBackendsViewWithWhatIntervalsAdds() throws {
        var state = AppState()
        let first = day.adding(days: 1)
        let event = try JSONDecoder().decode(IntervalsEvent.self, from: Data(#"{"id":77,"external_id":"cadencia-i1-p1-\#(first.iso)","category":"WORKOUT","start_date_local":"\#(first.iso)T00:00:00"}"#.utf8))
        state.calendarEvents = [event]
        state.activities = [ActivitySummary(id: "a1", name: "Ride", type: "Ride", startDateLocal: first.date(), movingTime: 3600,
                                            isTrainer: true, pairedEventID: 77, compliance: 91)]
        state.planContext = PlanContext(planId: "i1:p1", details: .init(objective: "Base", rationale: "Why", weeklyRides: []))
        state.adoptBackendPlan(view())
        let session = try XCTUnwrap(state.plan?.sessions.first { $0.day == first })
        XCTAssertEqual(session.intervalsEventID, 77)
        XCTAssertEqual(session.status, .completed)
        XCTAssertEqual(session.compliance, 91)
        XCTAssertEqual(state.plan?.consultation?.objective, "Base")
        XCTAssertEqual(state.workoutRequest(on: day.adding(days: 2))?.maxMinutes, 40)
        // Another plan drops the old plan's context; no plan drops the plan.
        state.adoptBackendPlan(view(planId: "i1:p2"))
        XCTAssertNil(state.planContext)
        XCTAssertNil(state.plan?.consultation)
        state.adoptBackendPlan(nil)
        XCTAssertNil(state.plan)
    }

    func testCachesSurviveARestartAndAStaleCacheNeverResetsTheState() throws {
        var state = AppState()
        take(&state)
        state.today?.decidedAt = day.date() // whole seconds survive ISO 8601
        state.coachThread = .init(.init(messages: [.init(messageId: "m1", role: .athlete, text: "Hi", at: "2028-03-17T08:00:00.000Z")]))
        state.consultation = .init(id: "i1:c1", startedOn: day, view: .init(.init(stage: .open, turns: [.init(role: .coach, text: "Goal?")])))
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(AppState.self, from: encoder.encode(state)), state)

        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(state)) as? [String: Any])
        json["coachThread"] = ["messages": [["unexpected": true]]]
        let restored = try decoder.decode(AppState.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(restored.coachThread?.value)
        XCTAssertEqual(restored.today, state.today)
    }

    func testStateFromBeforeTheBackendStillDecodes() throws {
        let legacy = """
        {"wellness":[],"activities":[],"powerCurve":[],"feedbackByDay":{},"ledger":{"entries":[]},"rideIndex":[],
         "coachMessages":[{"id":"\(UUID())","role":"coach","text":"Old","sentAt":0}],
         "workoutRequests":{},"planConsultation":{"id":"\(UUID())","startedOn":"2028-03-17","messages":[]},
         "settings":{},"healthAuthorized":false}
        """
        let state = try JSONDecoder().decode(AppState.self, from: Data(legacy.utf8))
        XCTAssertTrue(state.coachMessages.isEmpty)
        XCTAssertNil(state.consultation)
        XCTAssertNil(state.cyclistProfile)
    }

    func testOnlyAppliedProposalsCanAffectFutureDecisions() {
        var state = AppState()
        let at = ISO8601DateFormatter().string(from: day.date())
        let intent = CadenciaAPI.Intent(planId: "i1:p1", summary: "Shorter", limits: [.init(day: day.iso, maxMinutes: 40, unavailable: false)])
        state.coachThread = .init(.init(messages: [
            .init(messageId: "m1", role: .athlete, text: "Only 40 minutes today", at: at),
            .init(messageId: "m2", role: .coach, text: "Shorter, then", at: at, intent: intent, intentStatus: .proposed),
        ]))
        XCTAssertTrue(state.appliedCoachNotes(on: day).isEmpty)
        state.coachThread?.value?.messages[1].intentStatus = .applied
        XCTAssertEqual(state.appliedCoachNotes(on: day), ["Only 40 minutes today"])
        XCTAssertTrue(state.appliedCoachNotes(on: day.adding(days: 8)).isEmpty)
    }
}
