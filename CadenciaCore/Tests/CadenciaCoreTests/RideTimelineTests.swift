import XCTest
@testable import CadenciaCore

final class RideTimelineTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let ftp = 250

    private func workout() -> Workout {
        var steps = [WorkoutStep(name: "Warm-up", duration: 600, intensity: 0.5)]
        for _ in 0..<3 {
            steps.append(.init(name: "Effort", duration: 45, intensity: 1.1))
            steps.append(.init(name: "Recovery", duration: 120, intensity: 0.5))
        }
        steps.append(.init(name: "Cool-down", duration: 240, intensity: 0.45))
        return Workout(name: "Activation", kind: .openerActivation, steps: steps, intensityCeiling: 1.1)
    }

    private func roundTrip(_ ride: RideRecording) throws -> RideRecording {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(RideRecording.self, from: encoder.encode(ride))
    }

    func testLegacyDriftingTickerStillAlignsEffortsAfterRestart() throws {
        let workout = workout()
        let duration = workout.totalDuration
        var samples: [RideSample] = []
        var elapsed = 1.04
        while elapsed < duration {
            let target = workout.targetWatts(ftp: ftp, at: elapsed)!
            samples.append(.init(time: start.addingTimeInterval(elapsed), watts: target, targetWatts: target))
            elapsed += 1.04
        }
        let ride = try roundTrip(.init(athleteID: "athlete", workout: workout, startedAt: start,
            endedAt: start.addingTimeInterval(duration), samples: samples,
            timerEvents: [.init(time: start, kind: .start), .init(time: start.addingTimeInterval(duration), kind: .stop)]))
        XCTAssertLessThan(ride.samples.count, Int(duration))
        let timeline = RideTimeline(samples: ride.samples, startedAt: ride.startedAt, timerEvents: ride.timerEvents, endedAt: ride.endedAt)
        let blocks = ride.workout.steps.indices.map { RideCommentary.BlockStats.compute(index: $0, workout: ride.workout, ftp: ftp, timeline: timeline) }
        for index in [1, 3, 5] {
            let block = blocks[index]
            XCTAssertEqual(block.seconds, 45)
            XCTAssertEqual(try XCTUnwrap(block.avgWatts), 275, accuracy: 5)
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(block.inZonePercent), 95)
            XCTAssertEqual(block.powerCoveragePercent, 100)
        }
        XCTAssertEqual(blocks.last?.seconds, 240, "fewer observations do not mean an incomplete cool-down")
    }

    func testPausedTimeNeverShiftsWorkIntoAnotherBlock() throws {
        let workout = Workout(name: "Short intervals", kind: .threshold, steps: [
            .init(name: "Warm-up", duration: 10, intensity: 0.5),
            .init(name: "Work", duration: 5, intensity: 1),
            .init(name: "Cool-down", duration: 5, intensity: 0.5)])
        let samples = (0..<20).map { second -> RideSample in
            let wall = second < 10 ? second : second + 100
            let watts = (10..<15).contains(second) ? ftp : 125
            return .init(time: start.addingTimeInterval(Double(wall)), watts: watts, targetWatts: watts)
        } + [.init(time: start.addingTimeInterval(50), watts: 999, targetWatts: 999)]
        let events: [RideTimerEvent] = [.init(time: start, kind: .start), .init(time: start.addingTimeInterval(10), kind: .stop),
            .init(time: start.addingTimeInterval(110), kind: .start), .init(time: start.addingTimeInterval(120), kind: .stop)]
        let ride = RideRecording(athleteID: "a", workout: workout, startedAt: start, endedAt: start.addingTimeInterval(120),
                                 samples: samples, timerEvents: events)
        let timeline = RideTimeline(samples: ride.samples, startedAt: ride.startedAt, timerEvents: ride.timerEvents, endedAt: ride.endedAt)
        let blocks = ride.workout.steps.indices.map { RideCommentary.BlockStats.compute(index: $0, workout: ride.workout, ftp: ftp, timeline: timeline) }
        XCTAssertEqual(blocks.map(\.seconds), [10, 5, 5])
        XCTAssertEqual(blocks[1].avgWatts, ftp)
        XCTAssertEqual(blocks[1].inZonePercent, 100)
        XCTAssertEqual(blocks[1].powerCoveragePercent, 100)
    }

    func testIrregularObservationsUseTimeWeightedAveragesAndRecordedTargets() {
        let workout = Workout(name: "Steady", kind: .endurance, steps: [.init(name: "Main", duration: 3, intensity: 0.6)])
        let samples: [RideSample] = [.init(time: start, watts: 100, targetWatts: 100),
                                    .init(time: start.addingTimeInterval(2), watts: 200, targetWatts: 200)]
        let stats = RideCommentary.BlockStats.compute(index: 0, workout: workout, ftp: ftp, samples: samples,
            startedAt: start, endedAt: start.addingTimeInterval(3))
        XCTAssertEqual(stats.avgWatts, 133)
        XCTAssertEqual(stats.recordedTargetWatts, 133)
        XCTAssertEqual(stats.targetWatts, 150, "base prescription remains separate from manually adjusted targets")
        XCTAssertEqual(stats.inZonePercent, 100)
    }

    func testMissingPowerAndLongGapsRemainUnknownRatherThanMissedEfforts() {
        let workout = Workout(name: "Work", kind: .threshold, steps: [.init(name: "Work", duration: 10, intensity: 1)])
        let samples: [RideSample] = [.init(time: start, watts: ftp, targetWatts: ftp),
                                    .init(time: start.addingTimeInterval(1), watts: ftp, targetWatts: ftp)]
        let stats = RideCommentary.BlockStats.compute(index: 0, workout: workout, ftp: ftp, samples: samples,
            startedAt: start, endedAt: start.addingTimeInterval(10))
        XCTAssertEqual(stats.seconds, 10)
        XCTAssertEqual(stats.avgWatts, ftp)
        XCTAssertEqual(stats.inZonePercent, 100)
        XCTAssertEqual(stats.powerCoveragePercent, 60)
    }

    func testEngineRecordsActiveClockAcrossPausesAndKeepsItAfterDatePrecisionLoss() throws {
        let w = workout()
        var engine = RideEngine(recording: .init(athleteID: "a", workout: w, startedAt: start), ftp: ftp)
        engine.start(at: start)
        engine.tick(now: start.addingTimeInterval(0.4), watts: 125, heartRate: nil, cadence: nil)
        engine.pause(at: start.addingTimeInterval(0.8))
        engine.start(at: start.addingTimeInterval(100.8))
        engine.tick(now: start.addingTimeInterval(101.4), watts: 125, heartRate: nil, cadence: nil)
        engine.finish(at: start.addingTimeInterval(102))
        let restored = try roundTrip(engine.recording)
        XCTAssertEqual(try XCTUnwrap(restored.samples[0].workoutElapsed), 0.4, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(restored.samples[1].workoutElapsed), 1.4, accuracy: 0.001)
        let timeline = RideTimeline(samples: restored.samples, startedAt: restored.startedAt,
                                    timerEvents: restored.timerEvents, endedAt: restored.endedAt)
        XCTAssertEqual(timeline.observations.first?.start ?? 0, 0.4, accuracy: 0.001)
        XCTAssertEqual(timeline.observations.first?.end ?? 0, 0.8, accuracy: 0.001)
        XCTAssertEqual(timeline.observations.last?.start ?? 0, 1.4, accuracy: 0.001)
        XCTAssertEqual(timeline.duration, 2, accuracy: 0.001)
    }

    func testOldReportsRequireFreshEvidenceButCurrentReportsAndHeadUnitImportsDoNot() throws {
        var ride = RideRecording(athleteID: "a", workout: workout(), startedAt: start,
                                 samples: [.init(time: start, watts: 125)])
        let report = RideDebrief.Report(headline: "Old report", grade: .partial, benefit: "", execution: "", physiology: "", next: "", model: "test")
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as! [String: Any]
        json["evidenceRevision"] = nil
        ride.debrief = try JSONDecoder().decode(RideDebrief.Report.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertTrue(RideDebrief.requiresRefresh(ride))
        ride.debrief = report
        XCTAssertFalse(RideDebrief.requiresRefresh(ride))
        ride.debrief?.evidenceRevision = nil
        ride.sourceActivity = .init(id: "i1", name: "Head unit", type: "Ride", startDateLocal: start, movingTime: 60)
        XCTAssertTrue(RideDebrief.requiresRefresh(ride), "older reports from either recording source must migrate to provider-only evidence")
    }

    func testCorrectedNoteIsAppendedOnceWithoutReusingEarlierWrongAnalysis() async throws {
        let report = RideDebrief.Report(headline: "Corrected", grade: .excellent, benefit: "", execution: "", physiology: "", next: "", model: "test",
                                       correctionNotice: "Updated analysis.")
        let old = IntervalsActivityNote(id: 7, content: IntervalsActivityNote.coachPrefix + "Earlier assessment")
        let transport = FakeTransport(responses: [.init(status: 200, body: try JSONEncoder().encode([old])),
                                                   .init(status: 200, body: Data(#"{"id":8}"#.utf8))])
        let saved = try await IntervalsClient(transport: transport, credential: .apiKey("test")).saveDebriefNote(activityID: "i1", report: report)
        XCTAssertEqual(saved.id, 8)
        XCTAssertEqual(saved.content, report.noteContent)
        XCTAssertTrue(saved.content.contains("Updated analysis."))
        XCTAssertEqual(transport.requests.map(\.method), [.get, .post])
        let retry = FakeTransport(responses: [.init(status: 200, body: try JSONEncoder().encode([old, saved]))])
        let reconciled = try await IntervalsClient(transport: retry, credential: .apiKey("test")).saveDebriefNote(activityID: "i1", report: report)
        XCTAssertEqual(reconciled, saved)
        XCTAssertEqual(retry.requests.count, 1, "a lost correction POST is reconciled, never blindly posted again")
    }
}
