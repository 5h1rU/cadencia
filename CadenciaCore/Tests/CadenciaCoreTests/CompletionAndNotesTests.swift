import XCTest
@testable import CadenciaCore

final class CompletionAndNotesTests: XCTestCase {
    private let day = Day(year: 2026, month: 10, day: 29)
    private var workout: Workout {
        Workout(name: "Endurance", kind: .endurance, steps: [.init(name: "Z2", duration: 3600, intensity: 0.7)])
    }
    private var report: RideDebrief.Report {
        .init(headline: "A steady hour", grade: .good, benefit: "Aerobic work.", execution: "On target.",
              physiology: "Stable heart rate.", next: "Recover tonight.",
              blocks: [.init(index: 0, verdict: .hit, note: "Held Z2")], flags: ["Sleep well"], model: "coach")
    }

    func testCompletionUsesExplicitSessionLinkAndNeverCompletesAnotherSession() {
        let session = PlannedSession(day: day, kind: .endurance, title: "Plan", targetMinutes: 60, workout: workout)
        var ride = RideRecording(athleteID: "a", workout: workout, plannedSessionID: session.id, startedAt: day.date())
        XCTAssertFalse(ride.completes(session), "an in-progress ride has not completed the session")
        ride.endedAt = day.date().addingTimeInterval(3600)
        XCTAssertTrue(ride.completes(session))
        var other = session
        other.id = UUID()
        XCTAssertFalse(ride.completes(other), "same workout/day must not override an explicit session link")
    }

    func testUnlinkedLegacyRideMatchesWorkoutAndDayIncludingOutdoorDelivery() {
        let w = workout
        var session = PlannedSession(day: day, kind: .endurance, title: w.name, targetMinutes: 60, workout: w)
        var ride = RideRecording(athleteID: "a", workout: w, startedAt: day.date(), endedAt: day.date().addingTimeInterval(3600))
        XCTAssertTrue(ride.completes(session))
        ride.startedAt = day.adding(days: -1).date()
        XCTAssertFalse(ride.completes(session))
        ride.startedAt = day.date()
        session.workout = workout
        XCTAssertFalse(ride.completes(session))
        session.deliveredWorkout = w
        XCTAssertTrue(ride.completes(session))
    }

    func testNoteIncludesTheFullSummaryAndRecordingKeepsItAcrossRestart() throws {
        var ride = RideRecording(athleteID: "a", workout: workout, startedAt: day.date())
        let oldData = try JSONEncoder().encode(ride)
        XCTAssertNil(try JSONDecoder().decode(RideRecording.self, from: oldData).debriefNote)
        ride.debrief = report
        ride.debriefNote = .init(id: 42, content: report.noteContent)
        let restored = try JSONDecoder().decode(RideRecording.self, from: JSONEncoder().encode(ride))
        XCTAssertEqual(restored.debriefNote, ride.debriefNote)
        for text in [report.headline, report.benefit, report.execution, report.physiology, report.next, "Held Z2", "Sleep well"] {
            XCTAssertTrue(restored.debriefNote!.debriefText.contains(text))
        }
        XCTAssertFalse(restored.debriefNote!.debriefText.contains(IntervalsActivityNote.coachPrefix))
    }

    func testSavePostsToActivityNotesWithoutEditingExistingCommentsOrDescription() async throws {
        let t = FakeTransport(responses: [
            .init(status: 200, body: Data(#"[{"id":1,"content":"My own note"},{"id":2,"type":"ACTIVITY"}]"#.utf8)),
            .init(status: 200, body: Data(#"{"id":42}"#.utf8))
        ])
        let c = IntervalsClient(transport: t, credential: IntervalsCredential(accessToken: "k"))
        let note = try await c.saveDebriefNote(activityID: "i9", report: report)
        XCTAssertEqual(note.id, 42)
        XCTAssertEqual(t.requests.map(\.method), [.get, .post])
        XCTAssertEqual(t.requests.last?.url.path, "/api/v1/activity/i9/messages")
        let body = try JSONDecoder().decode([String: String].self, from: t.requests.last!.body!)
        XCTAssertEqual(body, ["content": report.noteContent])
    }

    func testLostPostResponseIsReconciledBeforeRetrying() async throws {
        let saved = IntervalsActivityNote(id: 42, content: report.noteContent)
        let t = FakeTransport(responses: [.init(status: 200, body: try JSONEncoder().encode([saved]))])
        let c = IntervalsClient(transport: t, credential: IntervalsCredential(accessToken: "k"))
        let note = try await c.saveDebriefNote(activityID: "i9", report: report)
        XCTAssertEqual(note, saved)
        XCTAssertEqual(t.requests.count, 1, "accepted Notes must never be blindly posted again")
    }

    func testFailedNoteReadDoesNotPostAndDeletedNotesAreIgnored() async throws {
        let t = FakeTransport(responses: [.init(status: 503, body: Data())])
        let c = IntervalsClient(transport: t, credential: IntervalsCredential(accessToken: "k"))
        do {
            _ = try await c.saveDebriefNote(activityID: "i9", report: report)
            XCTFail("expected a failed reconciliation")
        } catch { }
        XCTAssertEqual(t.requests.count, 1)
        XCTAssertFalse(IntervalsActivityNote(id: 42, content: report.noteContent, deleted: "2026-10-29T12:00:00Z").isCoachDebrief)
    }

    func testReconciliationReadsPastTheFirstHundredComments() async throws {
        let page = (1...100).map { IntervalsActivityNote(id: Int64($0), content: "Other comment") }
        let saved = IntervalsActivityNote(id: 101, content: report.noteContent)
        let t = FakeTransport(responses: [
            .init(status: 200, body: try JSONEncoder().encode(page)),
            .init(status: 200, body: try JSONEncoder().encode([saved]))
        ])
        let c = IntervalsClient(transport: t, credential: IntervalsCredential(accessToken: "k"))
        let note = try await c.saveDebriefNote(activityID: "i9", report: report)
        XCTAssertEqual(note, saved)
        XCTAssertTrue(t.requests.last!.url.query!.contains("sinceId=100"))
        XCTAssertTrue(t.requests.allSatisfy { $0.method == .get })
    }
}
