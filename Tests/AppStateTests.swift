import XCTest
import CadenciaCore

final class CoachStateTests: XCTestCase {
    let day = Day(year: 2028, month: 3, day: 17)
    func prescription() -> DailyPrescription {
        let workout = Workout(name: "Requested endurance", kind: .endurance, steps: [.init(name: "Main block", duration: 2400, intensity: 0.65)], intensityCeiling: 0.75, createdAt: day.date())
        return DailyPrescription(readiness: .init(level: .normal, score: 60, signals: [], missingData: [], summary: ""), workout: workout, week: [], note: .init(headline: "Endurance", body: "Recovered", session: "Your requested steady ride"), flags: [], model: "test", generatedAt: day.date())
    }
    func testReviewingDoesNotApplyAndDatedRequestsStaySeparateFromChatNotes() {
        var state = AppState()
        let intent = CoachIntent(workoutRequest: .init(day: day, instructions: "Endurance", maxMinutes: 40))
        let source = AppState.CoachMessage(role: .athlete, text: "Make it endurance", sentAt: day.date())
        state.coachMessages = [source, .init(role: .coach, text: "Proposed", sentAt: day.date(), intent: intent, sourceMessageID: source.id,
                                           workoutProposal: .init(prescription: prescription(), basisFingerprint: "basis", ftp: 265))]
        XCTAssertNil(state.today)
        XCTAssertNil(state.workoutRequests)
        XCTAssertTrue(state.appliedCoachNotes(on: day).isEmpty)
        state.applyCoachIntent(intent, on: day)
        XCTAssertEqual(state.workoutRequests?[day.iso]?.maxMinutes, 40)
        XCTAssertNil(state.today)
        XCTAssertNil(state.workoutRequests?[day.adding(days: 1).iso])
        XCTAssertFalse(state.coachMessages[1].applied)
    }
    func testAcceptingUpdatesOneSessionInPlaceAndPreservesIdentity() {
        var state = AppState()
        let event = TrainingEvent(name: "Event", day: day.adding(days: 5))
        state.plan = PlanBuilder().build(.init(goal: .event, startDay: day, endDay: event.day, event: event, availability: .init(hoursPerWeek: 7, minutesByWeekday: Dictionary(uniqueKeysWithValues: (1...7).map { ($0, 60) }), longRideWeekday: 1)))
        state.plan!.sessions[0].intervalsEventID = 42
        let before = state.plan!
        state.acceptPrescription(prescription(), day: day, ftp: 265)
        XCTAssertEqual(state.plan?.id, before.id)
        XCTAssertEqual(state.plan?.sessions[0].id, before.sessions[0].id)
        XCTAssertEqual(state.plan?.sessions[0].intervalsEventID, 42)
        XCTAssertEqual(state.plan?.sessions[0].workout, state.today?.workout)
        XCTAssertEqual(state.plan?.sessions[0].prescriptionFTP, 265)
        XCTAssertEqual(state.plan?.sessions[0].kind, .endurance)
        XCTAssertEqual(Array(state.plan!.sessions.dropFirst()), Array(before.sessions.dropFirst()))
    }
    func testStandaloneUpdatesReuseIdentityAndCompletedSessionsCannotBeReplaced() {
        var state = AppState()
        state.acceptPrescription(prescription(), day: day, ftp: 265)
        let id = state.standaloneSessions![0].id
        state.acceptPrescription(prescription(), day: day, ftp: 265)
        XCTAssertEqual(state.standaloneSessions?.count, 1)
        XCTAssertEqual(state.standaloneSessions?[0].id, id)
        state.today?.completedRideID = UUID()
        let completed = state
        state.acceptPrescription(prescription(), day: day, ftp: 265)
        XCTAssertEqual(state, completed)
    }
    func testFutureRequestDoesNotReplaceTodaysWorkoutAndMetadataSurvivesRestart() throws {
        var state = AppState()
        state.acceptPrescription(prescription(), day: day, ftp: 265)
        let original = state.today
        let future = day.adding(days: 4)
        state.applyCoachIntent(.init(workoutRequest: .init(day: future, instructions: "A shorter ride", maxMinutes: 30)), on: day)
        XCTAssertEqual(state.today, original)
        XCTAssertNil(state.workoutRequests?[day.iso])
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(AppState.self, from: encoder.encode(state)), state)
    }
    func testLegacyStateStillDecodesWithoutNewOptionalFields() throws {
        var state = AppState()
        state.acceptPrescription(prescription(), day: day, ftp: 265)
        state.coachMessages = [.init(role: .coach, text: "Existing message", sentAt: day.date())]
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        var json = try JSONSerialization.jsonObject(with: encoder.encode(state)) as! [String: Any]
        json["workoutRequests"] = nil
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(AppState.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(restored, state)
        XCTAssertNil(restored.workoutRequests)
        XCTAssertTrue(restored.coachMessages.allSatisfy { $0.workoutProposal == nil && $0.sourceMessageID == nil })
    }

    func testOnlyAppliedContextNotesCanAffectFutureDecisions() {
        var state = AppState()
        let source = AppState.CoachMessage(role: .athlete, text: "Legs feel heavy", sentAt: day.date())
        state.coachMessages = [source, .init(role: .coach, text: "Proposal", sentAt: day.date(), intent: .init(feeling: .heavy), sourceMessageID: source.id)]
        XCTAssertTrue(state.appliedCoachNotes(on: day).isEmpty)
        state.coachMessages[1].applied = true
        XCTAssertEqual(state.appliedCoachNotes(on: day), [source.text])
        XCTAssertTrue(state.appliedCoachNotes(on: day.adding(days: 8)).isEmpty)
    }
}
