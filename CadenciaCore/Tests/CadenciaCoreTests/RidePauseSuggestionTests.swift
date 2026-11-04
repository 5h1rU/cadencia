import XCTest
@testable import CadenciaCore

final class RidePauseSuggestionTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)

    private func makeEngine(duration: TimeInterval = 120) -> RideEngine {
        let workout = Workout(name: "Steady", kind: .endurance, steps: [
            WorkoutStep(name: "Steady", duration: duration, intensity: 0.65)
        ])
        let recording = RideRecording(athleteID: "i1", workout: workout, startedAt: start)
        var engine = RideEngine(recording: recording, ftp: 200)
        engine.start(at: start)
        return engine
    }

    private func tick(_ engine: inout RideEngine, at seconds: TimeInterval, watts: Int? = 0, cadence: Int? = 0) {
        engine.tick(now: start.addingTimeInterval(seconds), watts: watts, heartRate: 120, cadence: cadence)
    }

    func testSuggestsAfterFiveSecondsAndKeepsRidingUntilConfirmed() {
        var engine = makeEngine()
        tick(&engine, at: 0, watts: 130, cadence: 85)
        for second in 1...5 {
            tick(&engine, at: Double(second))
            XCTAssertFalse(engine.shouldSuggestPause, "fewer than five seconds since the first zero reading")
        }
        tick(&engine, at: 6)
        XCTAssertTrue(engine.shouldSuggestPause)
        tick(&engine, at: 7)
        XCTAssertTrue(engine.shouldSuggestPause)
        XCTAssertEqual(engine.state, .riding, "the athlete must choose Pause")
        XCTAssertEqual(engine.elapsed, 7)
        XCTAssertEqual(engine.recording.samples.count, 8)
    }

    func testCadenceTakesPriorityOverPowerAndAnyPedalingResetsTheCountdown() {
        var engine = makeEngine()
        // A spinning flywheel can still report watts after the pedals stop.
        for second in 0...5 { tick(&engine, at: Double(second), watts: 90) }
        XCTAssertTrue(engine.shouldSuggestPause)
        tick(&engine, at: 6, cadence: 1)
        XCTAssertFalse(engine.shouldSuggestPause, "even slow pedaling with zero watts counts")
        for second in 7...11 { tick(&engine, at: Double(second)) }
        XCTAssertFalse(engine.shouldSuggestPause)
        tick(&engine, at: 12)
        XCTAssertTrue(engine.shouldSuggestPause)
    }

    func testPowerIsTheFallbackWhenCadenceIsUnavailable() {
        var engine = makeEngine()
        for second in 0...6 { tick(&engine, at: Double(second), watts: 20, cadence: nil) }
        XCTAssertFalse(engine.shouldSuggestPause)
        for second in 7...11 { tick(&engine, at: Double(second), cadence: nil) }
        XCTAssertFalse(engine.shouldSuggestPause)
        tick(&engine, at: 12, cadence: nil)
        XCTAssertTrue(engine.shouldSuggestPause)
        tick(&engine, at: 13, watts: 1, cadence: nil)
        XCTAssertFalse(engine.shouldSuggestPause)
    }

    func testMissingSensorsAndHeartRateAloneNeverTriggerAPrompt() {
        var engine = makeEngine()
        for second in 0...10 { tick(&engine, at: Double(second), watts: nil, cadence: nil) }
        XCTAssertFalse(engine.shouldSuggestPause)
        for second in 11...15 { tick(&engine, at: Double(second)) }
        XCTAssertFalse(engine.shouldSuggestPause)
        tick(&engine, at: 16, watts: nil, cadence: nil)
        for second in 17...21 { tick(&engine, at: Double(second)) }
        XCTAssertFalse(engine.shouldSuggestPause, "a sensor gap breaks continuous confirmed inactivity")
        tick(&engine, at: 22)
        XCTAssertTrue(engine.shouldSuggestPause)
        tick(&engine, at: 23, watts: nil, cadence: nil)
        XCTAssertFalse(engine.shouldSuggestPause)
    }

    func testKeepRidingPromptsOnlyOncePerStopAndRearmsAfterPedaling() {
        var engine = makeEngine()
        for second in 0...5 { tick(&engine, at: Double(second)) }
        XCTAssertTrue(engine.shouldSuggestPause)
        engine.dismissPauseSuggestion()
        for second in 6...12 { tick(&engine, at: Double(second)) }
        XCTAssertFalse(engine.shouldSuggestPause)
        tick(&engine, at: 13, watts: nil, cadence: nil)
        for second in 14...20 { tick(&engine, at: Double(second)) }
        XCTAssertFalse(engine.shouldSuggestPause, "a sensor gap must not rearm a dismissed prompt")
        tick(&engine, at: 21, watts: 130, cadence: 85)
        for second in 22...26 { tick(&engine, at: Double(second)) }
        XCTAssertFalse(engine.shouldSuggestPause)
        tick(&engine, at: 27)
        XCTAssertTrue(engine.shouldSuggestPause)
    }

    func testPauseClearsPromptAndResumeStartsANewCountdownWithoutCountingPausedTime() {
        var engine = makeEngine()
        for second in 0...5 { tick(&engine, at: Double(second)) }
        XCTAssertTrue(engine.shouldSuggestPause)
        engine.pause()
        XCTAssertFalse(engine.shouldSuggestPause)
        tick(&engine, at: 60)
        XCTAssertFalse(engine.shouldSuggestPause)
        XCTAssertEqual(engine.elapsed, 5)
        engine.start(at: start.addingTimeInterval(60))
        for second in 61...65 { tick(&engine, at: Double(second)) }
        XCTAssertFalse(engine.shouldSuggestPause)
        tick(&engine, at: 66)
        XCTAssertTrue(engine.shouldSuggestPause)
        XCTAssertEqual(engine.elapsed, 11)
    }

    func testFinishClearsPromptAndWorkoutCompletionTakesPriority() {
        var engine = makeEngine()
        for second in 0...5 { tick(&engine, at: Double(second)) }
        XCTAssertTrue(engine.shouldSuggestPause)
        engine.finish(at: start.addingTimeInterval(6))
        XCTAssertFalse(engine.shouldSuggestPause)
        tick(&engine, at: 20)
        XCTAssertFalse(engine.shouldSuggestPause)

        var shortWorkout = makeEngine(duration: 5)
        for second in 0...5 { tick(&shortWorkout, at: Double(second)) }
        XCTAssertEqual(shortWorkout.state, .finished)
        XCTAssertFalse(shortWorkout.shouldSuggestPause)
    }

    func testCountdownUsesElapsedTimeInsteadOfNumberOfTicks() {
        var engine = makeEngine()
        tick(&engine, at: 1)
        tick(&engine, at: 2.5)
        tick(&engine, at: 5.99)
        XCTAssertFalse(engine.shouldSuggestPause)
        tick(&engine, at: 6)
        XCTAssertTrue(engine.shouldSuggestPause)
    }
}
