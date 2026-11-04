import XCTest
@testable import CadenciaCore

final class OutdoorWorkoutTests: XCTestCase {
    private let day = Day(year: 2026, month: 10, day: 29)

    private var workout: Workout {
        Workout(name: "Readiness endurance", kind: .endurance, steps: [
            WorkoutStep(name: "Warm-up", duration: 600, startIntensity: 0.45, endIntensity: 0.8),
            WorkoutStep(name: "Endurance", duration: 1800, intensity: 0.75, cadenceRPM: 88)
        ], intensityCeiling: 0.69)
    }

    func testHigherOutdoorFTPCannotRaisePrescribedWattsAndExportUsesAbsoluteTargets() {
        let prepared = OutdoorWorkout(workout: workout, prescriptionFTP: 200, outdoorFTP: 250)
        XCTAssertEqual(prepared.ftp, 250)
        for time in stride(from: 0.0, to: workout.totalDuration, by: 10) {
            XCTAssertLessThanOrEqual(prepared.workout.targetWatts(ftp: 250, at: time)!, workout.targetWatts(ftp: 200, at: time)!)
        }
        XCTAssertTrue(prepared.text.contains("ramp 90-138w"))
        XCTAssertTrue(prepared.text.contains("30m 138w 88rpm"))
        XCTAssertFalse(prepared.text.contains("%"))
    }

    func testLowerOutdoorFTPSoftensAndCeilingIsNotRoundedUp() {
        let prepared = OutdoorWorkout(workout: workout, prescriptionFTP: 250, outdoorFTP: 200)
        XCTAssertTrue(prepared.text.contains("30m 138w"))
        var capped = workout
        capped.intensityCeiling = 0.696
        XCTAssertTrue(WorkoutText.render(capped).contains("30m 69%"))
        XCTAssertFalse(WorkoutText.render(capped).contains("70%"))
    }

    func testDeliveryRevisionChangesWithTargetsFTPOrDate() {
        let a = OutdoorWorkout(workout: workout, prescriptionFTP: 200, outdoorFTP: 250)
        var changed = workout
        changed.steps[1].duration += 60
        let b = OutdoorWorkout(workout: changed, prescriptionFTP: 200, outdoorFTP: 250)
        XCTAssertNotEqual(a.revision(on: day), b.revision(on: day))
        XCTAssertNotEqual(a.revision(on: day), a.revision(on: day.adding(days: 1)))
        XCTAssertNotEqual(a.revision(on: day), OutdoorWorkout(workout: workout, prescriptionFTP: 200, outdoorFTP: 240).revision(on: day))
    }

    func testOldPlanAndRideJSONStillDecodeWithoutOutdoorFields() throws {
        let session = PlannedSession(day: day, kind: .endurance, title: "Endurance", targetMinutes: 60)
        let data = try JSONEncoder().encode(session)
        let restored = try JSONDecoder().decode(PlannedSession.self, from: data)
        XCTAssertNil(restored.location)
        XCTAssertNil(restored.deliveredWorkout)
        let ride = RideRecording(athleteID: "i1", workout: workout, startedAt: day.date())
        let restoredRide = try JSONDecoder().decode(RideRecording.self, from: JSONEncoder().encode(ride))
        XCTAssertNil(restoredRide.sourceActivity)
        XCTAssertNil(restoredRide.ftpUsed)
    }

    func testOnlyExplicitOutdoorPairingMatchesAndImportedIDsAreStablePerAthlete() {
        var session = PlannedSession(day: day, kind: .endurance, title: "Endurance", targetMinutes: 60, intervalsEventID: 42, location: .outdoor)
        var activity = ActivitySummary(id: "i9", name: "Endurance", type: "Ride", startDateLocal: day.date(), movingTime: 3600, pairedEventID: 42)
        XCTAssertTrue(OutdoorRideImport.matches(activity, session: session))
        activity.pairedEventID = nil
        XCTAssertFalse(OutdoorRideImport.matches(activity, session: session), "same date/name is not identity")
        activity.pairedEventID = 42
        activity.isTrainer = true
        XCTAssertFalse(OutdoorRideImport.matches(activity, session: session))
        activity.isTrainer = false
        session.location = .indoor
        XCTAssertFalse(OutdoorRideImport.matches(activity, session: session))
        XCTAssertEqual(OutdoorRideImport.recordingID(athleteID: "i1", activityID: "i9"), OutdoorRideImport.recordingID(athleteID: "i1", activityID: "i9"))
        XCTAssertNotEqual(OutdoorRideImport.recordingID(athleteID: "i1", activityID: "i9"), OutdoorRideImport.recordingID(athleteID: "i2", activityID: "i9"))
    }

    func testOutdoorCalendarUpdatePreservesEventIDAndSendsWattsAndLocation() async throws {
        let transport = FakeTransport(responses: [.init(status: 200, body: Data(#"{"id":42}"#.utf8))])
        let prepared = OutdoorWorkout(workout: workout, prescriptionFTP: 200, outdoorFTP: 250)
        let session = PlannedSession(day: day, kind: .endurance, title: "Endurance", targetMinutes: 40,
            status: .generated, workout: prepared.workout, intervalsEventID: 42, location: .outdoor)
        _ = try await IntervalsClient(transport: transport, credential: .apiKey("k")).upsertPlannedWorkout(session, ftp: prepared.ftp)
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.method, .put)
        XCTAssertEqual(request.url.path, "/api/v1/athlete/0/events/42")
        let body = try JSONSerialization.jsonObject(with: request.body!) as! [String: Any]
        XCTAssertEqual(body["indoor"] as? Bool, false)
        XCTAssertTrue((body["description"] as! String).contains("138w"))
        XCTAssertNil(body["uid"])
    }

    func testFITExportSelectsExactServerEventAndResolvesPower() async throws {
        var fit = Data(repeating: 0, count: 32)
        fit.replaceSubrange(8..<12, with: Data(".FIT".utf8))
        let json = "[{\"id\":41,\"workout_file_base64\":\"bad\"},{\"id\":42,\"workout_file_base64\":\"\(fit.base64EncodedString())\"}]"
        let transport = FakeTransport(responses: [.init(status: 200, body: Data(json.utf8))])
        let result = try await IntervalsClient(transport: transport, credential: .apiKey("k")).plannedWorkoutFIT(eventID: 42, day: day)
        XCTAssertEqual(result, fit)
        let url = try XCTUnwrap(transport.requests.first?.url)
        XCTAssertEqual(url.path, "/api/v1/athlete/0/events")
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertTrue(query.contains(URLQueryItem(name: "resolve", value: "true")))
        XCTAssertTrue(query.contains(URLQueryItem(name: "ext", value: "fit")))
    }

    func testMissingOrMalformedFITIsAnError() async {
        for json in [#"[{"id":41}]"#, #"[{"id":42,"workout_file_base64":"YmFk"}]"#] {
            let transport = FakeTransport(responses: [.init(status: 200, body: Data(json.utf8))])
            do {
                _ = try await IntervalsClient(transport: transport, credential: .apiKey("k")).plannedWorkoutFIT(eventID: 42, day: day)
                XCTFail("must not share a missing or corrupt workout")
            } catch { XCTAssertEqual(error as? HTTPError, .invalidResponse) }
        }
    }

    func testHeadUnitDebriefUsesActualTotalsWithoutInventedPhoneSamples() {
        let activity = ActivitySummary(id: "i9", name: "Outside", type: "Ride", startDateLocal: day.date(), movingTime: 3600,
            trainingLoad: 55, averageWatts: 150, normalizedWatts: 170, averageHR: 140, pairedEventID: 42)
        let ride = RideRecording(athleteID: "i1", workout: workout, startedAt: activity.startDateLocal,
            endedAt: activity.startDateLocal.addingTimeInterval(3600), sourceActivity: activity, ftpUsed: 250)
        let brief = RideDebrief.Brief(locale: "en", ride: ride, ftp: 250, recentActivities: [activity], analysis: ActivityDetail(id: "i9", name: "Outside", analyzed: true, movingTime: 3600, trainingLoad: 55, averageWatts: 150, kilojoules: 540))
        XCTAssertEqual(brief.intervals?.avgWatts, 150)
        XCTAssertEqual(brief.intervals?.trainingLoad, 55)
        XCTAssertEqual(brief.intervals?.kilojoules, 540)
        XCTAssertEqual(brief.analysisSource, "intervals.icu")
        XCTAssertTrue(brief.context.recentActivities.isEmpty)
    }
}
