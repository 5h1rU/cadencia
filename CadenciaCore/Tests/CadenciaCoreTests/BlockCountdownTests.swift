import XCTest
@testable import CadenciaCore

final class BlockCountdownTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func engine(durations: [TimeInterval] = [10, 5]) -> RideEngine {
        let workout = Workout(name: "Countdown", kind: .endurance,
                              steps: durations.map { WorkoutStep(name: "Block", duration: $0, intensity: 0.6) })
        return RideEngine(recording: .init(athleteID: "a", workout: workout, startedAt: start), ftp: 200)
    }

    private func tick(_ engine: inout RideEngine, at seconds: TimeInterval) {
        engine.tick(now: start.addingTimeInterval(seconds), watts: 120, heartRate: nil, cadence: 90)
    }

    func testEachBlockIncludingFinalBlockEmitsThreeTwoOneExactlyOnce() {
        var engine = engine()
        var countdown = BlockCountdown()
        engine.start(at: start)
        var cues: [Int] = []
        for second in 0...15 {
            tick(&engine, at: Double(second))
            if let cue = countdown.update(for: engine) { cues.append(cue) }
            XCTAssertNil(countdown.update(for: engine), "the same tick never beeps twice")
        }
        XCTAssertEqual(cues, [3, 2, 1, 3, 2, 1])
        XCTAssertEqual(engine.state, .finished)
    }

    func testFractionalTicksWaitUntilFinalThreeSeconds() {
        var engine = engine()
        var countdown = BlockCountdown()
        engine.start(at: start)
        tick(&engine, at: 6.99)
        XCTAssertNil(countdown.update(for: engine))
        tick(&engine, at: 7.05)
        XCTAssertEqual(countdown.update(for: engine), 3)
        tick(&engine, at: 7.9)
        XCTAssertNil(countdown.update(for: engine))
        tick(&engine, at: 8.05)
        XCTAssertEqual(countdown.update(for: engine), 2)
        tick(&engine, at: 9.05)
        XCTAssertEqual(countdown.update(for: engine), 1)
    }

    func testPauseAndResumeDoNotBeepWhilePausedOrReplayCurrentSecond() {
        var engine = engine()
        var countdown = BlockCountdown()
        XCTAssertNil(countdown.update(for: engine))
        engine.start(at: start)
        tick(&engine, at: 7)
        XCTAssertEqual(countdown.update(for: engine), 3)
        engine.pause(at: start.addingTimeInterval(7.2))
        XCTAssertNil(countdown.update(for: engine))
        engine.start(at: start.addingTimeInterval(100))
        XCTAssertNil(countdown.update(for: engine))
        tick(&engine, at: 101)
        XCTAssertEqual(countdown.update(for: engine), 2)
        engine.finish(at: start.addingTimeInterval(101))
        XCTAssertNil(countdown.update(for: engine))
    }

    func testDelayedTicksSkipMissedCuesAndDoNotReplayPreviousBlocks() {
        var engine = engine(durations: [10, 10])
        var countdown = BlockCountdown()
        engine.start(at: start)
        tick(&engine, at: 8.2)
        XCTAssertEqual(countdown.update(for: engine), 2)
        tick(&engine, at: 10.5)
        XCTAssertNil(countdown.update(for: engine))
        tick(&engine, at: 19.2)
        XCTAssertEqual(countdown.update(for: engine), 1)
        tick(&engine, at: 25)
        XCTAssertNil(countdown.update(for: engine))
    }

    func testShortBlocksCueImmediatelyAndRearmAtTheNextBlock() {
        var engine = engine(durations: [3, 3, 1])
        var countdown = BlockCountdown()
        engine.start(at: start)
        XCTAssertEqual(countdown.update(for: engine), 3)
        tick(&engine, at: 3)
        XCTAssertEqual(countdown.update(for: engine), 3)
        tick(&engine, at: 6)
        XCTAssertEqual(countdown.update(for: engine), 1)
    }
}
