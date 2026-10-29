import XCTest
@testable import CadenciaCore

final class BLEProtocolTests: XCTestCase {
    func testIndoorBikeDataWithSpeedCadencePowerAndHeartRate() {
        // flags: bit0=0 (speed present), bit2 cadence, bit6 power, bit9 HR → 0x0244
        let data = Data([0x44, 0x02,
                         0xD0, 0x07,   // speed 2000 → 20.00 km/h
                         0xAE, 0x00,   // cadence 174 → 87 rpm
                         0x98, 0x00,   // power 152 W
                         0x80])        // HR 128
        let d = IndoorBikeData.parse(data)!
        XCTAssertEqual(d.speedKmh, 20)
        XCTAssertEqual(d.cadenceRPM, 87)
        XCTAssertEqual(d.instantaneousPower, 152)
        XCTAssertEqual(d.heartRate, 128)
        XCTAssertNil(d.averagePower)
    }

    func testIndoorBikeDataMoreDataBitMeansNoSpeedField() {
        // flags: bit0=1 (no speed), bit6 power → 0x0041
        let data = Data([0x41, 0x00, 0xFF, 0xFF]) // power −1 (sint16)
        let d = IndoorBikeData.parse(data)!
        XCTAssertNil(d.speedKmh)
        XCTAssertEqual(d.instantaneousPower, -1)
    }

    func testIndoorBikeDataSkipsAverageSpeedAndDistanceCorrectly() {
        // bit0=1, bit1 avg speed, bit4 total distance (uint24), bit6 power → 0x0053
        let data = Data([0x53, 0x00, 0x10, 0x27, 0x01, 0x00, 0x01, 0x2C, 0x01])
        let d = IndoorBikeData.parse(data)!
        XCTAssertEqual(d.totalDistanceMeters, 65537)
        XCTAssertEqual(d.instantaneousPower, 300)
    }

    func testTruncatedPacketDoesNotCrash() {
        XCTAssertNil(IndoorBikeData.parse(Data([0x44])))
        let d = IndoorBikeData.parse(Data([0x44, 0x02, 0xD0]))!
        XCTAssertNil(d.speedKmh)
    }

    func testControlPointEncodings() {
        XCTAssertEqual(FTMSControl.setTargetPower(152), Data([0x05, 0x98, 0x00]))
        XCTAssertEqual(FTMSControl.setTargetPower(300), Data([0x05, 0x2C, 0x01]))
        XCTAssertEqual(FTMSControl.requestControl(), Data([0x00]))
        XCTAssertEqual(FTMSControl.pause(), Data([0x08, 0x02]))
        XCTAssertEqual(FTMSControl.setSimulation(gradePercent: -1.5), Data([0x11, 0x00, 0x00, 0x6A, 0xFF, 40, 51]))
        let resp = FTMSControl.parseResponse(Data([0x80, 0x05, 0x01]))!
        XCTAssertEqual(resp.request, .setTargetPower)
        XCTAssertEqual(resp.result, .success)
        XCTAssertEqual(FTMSControl.parseResponse(Data([0x80, 0x00, 0x05]))?.result, .controlNotPermitted)
    }

    func testHeartRateUInt8AndUInt16WithRR() {
        let a = HeartRateMeasurement.parse(Data([0x00, 0x48]))!
        XCTAssertEqual(a.bpm, 72)
        XCTAssertNil(a.sensorContact)
        // flags: 16-bit HR, contact supported+detected (0x06), RR present (0x10) → 0x17
        let b = HeartRateMeasurement.parse(Data([0x17, 0x80, 0x00, 0x00, 0x04, 0x00, 0x03]))!
        XCTAssertEqual(b.bpm, 128)
        XCTAssertEqual(b.sensorContact, true)
        XCTAssertEqual(b.rrIntervals.count, 2)
        XCTAssertEqual(b.rrIntervals[0], 1.0)
        XCTAssertEqual(b.rrIntervals[1], 0.75)
    }

    func testCyclingPowerCadenceFromCrankDataHandlesWrap() {
        // flags bit5 crank data: watts 250, revs 65535 @ t 65000; then revs 1 @ t 1000 (wrapped)
        let p0 = CyclingPowerMeasurement.parse(Data([0x20, 0x00, 0xFA, 0x00, 0xFF, 0xFF, 0xE8, 0xFD]))!
        let p1 = CyclingPowerMeasurement.parse(Data([0x20, 0x00, 0xFA, 0x00, 0x01, 0x00, 0xE8, 0x03]))!
        XCTAssertEqual(p0.watts, 250)
        let cadence = CyclingPowerMeasurement.cadence(previous: p0, current: p1)!
        // 2 revs over (1000 − 65000 + 65536) = 1536 ticks = 1.5 s → 80 rpm
        XCTAssertEqual(cadence, 80, accuracy: 0.01)
        XCTAssertNil(CyclingPowerMeasurement.cadence(previous: p1, current: p1))
    }
}

final class RideEngineTests: XCTestCase {
    func makeEngine(ceiling: Double? = 0.69) -> RideEngine {
        let workout = Workout(name: "E", kind: .endurance, steps: [
            WorkoutStep(name: "Warm-up", duration: 10, startIntensity: 0.5, endIntensity: 0.6),
            WorkoutStep(name: "Steady", duration: 20, intensity: 0.65),
        ], intensityCeiling: ceiling)
        let rec = RideRecording(athleteID: "i1", workout: workout, startedAt: Date(timeIntervalSince1970: 0))
        return RideEngine(recording: rec, ftp: 200)
    }

    func testTickAdvancesStepsRecordsSamplesAndFinishes() {
        var e = makeEngine()
        let t0 = Date(timeIntervalSince1970: 1000)
        XCTAssertNil(e.tick(now: t0, watts: 100, heartRate: 120, cadence: 85), "not started yet")
        e.start(at: t0)
        XCTAssertEqual(e.targetWatts, 100)
        XCTAssertEqual(e.currentStepIndex, 0)
        for i in 1...10 { e.tick(now: t0.addingTimeInterval(Double(i)), watts: 110, heartRate: 125, cadence: 88) }
        XCTAssertEqual(e.currentStepIndex, 1)
        XCTAssertEqual(e.targetWatts, 130)
        XCTAssertEqual(e.recording.samples.count, 10)
        XCTAssertEqual(e.recording.samples.last?.targetWatts, 130)
        for i in 11...30 { e.tick(now: t0.addingTimeInterval(Double(i)), watts: 130, heartRate: 130, cadence: 88) }
        XCTAssertEqual(e.state, .finished)
        XCTAssertEqual(e.recording.endedAt, t0.addingTimeInterval(30))
        XCTAssertEqual(e.progress, 1)
    }

    func testPauseStopsTheClockAndResumeDoesNotJump() {
        var e = makeEngine()
        let t0 = Date(timeIntervalSince1970: 1000)
        e.start(at: t0)
        e.tick(now: t0.addingTimeInterval(5), watts: 100, heartRate: nil, cadence: nil)
        e.pause()
        XCTAssertNil(e.tick(now: t0.addingTimeInterval(500), watts: 100, heartRate: nil, cadence: nil))
        e.start(at: t0.addingTimeInterval(500))
        e.tick(now: t0.addingTimeInterval(501), watts: 100, heartRate: nil, cadence: nil)
        XCTAssertEqual(e.elapsed, 6, accuracy: 0.001)
    }

    func testIntensityScaleNeverExceedsCeiling() {
        var e = makeEngine()
        e.start(at: Date(timeIntervalSince1970: 0))
        for i in 1...10 { e.tick(now: Date(timeIntervalSince1970: Double(i)), watts: 1, heartRate: nil, cadence: nil) }
        XCTAssertEqual(e.targetWatts, 130)
        e.adjustIntensity(by: 0.2)
        XCTAssertEqual(e.intensityScale, 1.2)
        XCTAssertEqual(e.targetWatts, 138, "0.65 × 1.2 = 0.78 clamps to the 0.69 ceiling → 138 W")
        e.adjustIntensity(by: 0.5)
        XCTAssertEqual(e.intensityScale, 1.2, "scale itself is bounded")
        e.adjustIntensity(by: -1)
        XCTAssertEqual(e.intensityScale, 0.8)
        XCTAssertEqual(e.targetWatts, 104)
    }
}

final class RideCommentaryTests: XCTestCase {
    // Warm-up 5', Z4 block 10', cool-down 5'. FTP 200.
    let workout = Workout(name: "Threshold taster", kind: .threshold, steps: [
        WorkoutStep(name: "Warm-up", duration: 300, startIntensity: 0.5, endIntensity: 0.65),
        WorkoutStep(name: "Threshold", duration: 600, intensity: 1.0),
        WorkoutStep(name: "Cool-down", duration: 300, intensity: 0.45),
    ], rationale: "Short threshold touch.")

    func testSchedulerFiresEachMomentOnce() {
        var s = RideCommentary.Scheduler()
        XCTAssertNil(s.due(stepIndex: 0, elapsedInStep: 2, stepDuration: 300, finished: false), "the trainer has not settled yet")
        XCTAssertEqual(s.due(stepIndex: 0, elapsedInStep: 8, stepDuration: 300, finished: false), .blockStart(0))
        XCTAssertNil(s.due(stepIndex: 0, elapsedInStep: 9, stepDuration: 300, finished: false), "block start is said once")
        XCTAssertNil(s.due(stepIndex: 0, elapsedInStep: 200, stepDuration: 300, finished: false), "a 5-minute block has no mid-block cue")
        XCTAssertEqual(s.due(stepIndex: 1, elapsedInStep: 8, stepDuration: 600, finished: false), .blockStart(1))
        XCTAssertNil(s.due(stepIndex: 1, elapsedInStep: 299, stepDuration: 600, finished: false))
        XCTAssertEqual(s.due(stepIndex: 1, elapsedInStep: 300, stepDuration: 600, finished: false), .midBlock(1))
        XCTAssertNil(s.due(stepIndex: 1, elapsedInStep: 301, stepDuration: 600, finished: false))
        XCTAssertEqual(s.due(stepIndex: nil, elapsedInStep: 0, stepDuration: 0, finished: true), .finish)
        XCTAssertNil(s.due(stepIndex: nil, elapsedInStep: 0, stepDuration: 0, finished: true))
    }

    func testBlockStatsAreSlicedByBlockOffset() {
        // 300 s warm-up at 100 W (target ramps 100→130), then 60 s of threshold at 198–202 W on a 200 W target.
        var samples: [RideSample] = (0..<300).map { s in
            RideSample(time: Date(timeIntervalSince1970: Double(s)), watts: 100, heartRate: 110, cadence: 85, targetWatts: 100 + s / 10)
        }
        samples += (0..<60).map { s in
            RideSample(time: Date(timeIntervalSince1970: 300 + Double(s)), watts: s % 2 == 0 ? 198 : 202, heartRate: 150, cadence: 90, targetWatts: 200)
        }
        let warmUp = RideCommentary.BlockStats.compute(index: 0, workout: workout, ftp: 200, samples: samples)
        XCTAssertEqual(warmUp.seconds, 300)
        XCTAssertEqual(warmUp.avgWatts, 100)
        XCTAssertEqual(warmUp.avgHeartRate, 110)
        XCTAssertEqual(warmUp.targetWatts, 115, "midpoint of the 0.5→0.65 ramp at FTP 200")
        // 100 W is within 10 % of the target only while the ramp target is ≤ 111 W: the first 120 samples.
        XCTAssertEqual(warmUp.inZonePercent, 40)

        let threshold = RideCommentary.BlockStats.compute(index: 1, workout: workout, ftp: 200, samples: samples, upTo: 360)
        XCTAssertEqual(threshold.seconds, 60)
        XCTAssertEqual(threshold.avgWatts, 200)
        XCTAssertEqual(threshold.maxWatts, 202)
        XCTAssertEqual(threshold.inZonePercent, 100)

        let empty = RideCommentary.BlockStats.compute(index: 2, workout: workout, ftp: 200, samples: samples)
        XCTAssertEqual(empty.seconds, 0)
        XCTAssertNil(empty.avgWatts)
        XCTAssertNil(empty.inZonePercent)
    }

    func testBriefCarriesPreviousCurrentAndNextBlocks() throws {
        let samples: [RideSample] = (0..<300).map { s in RideSample(time: Date(timeIntervalSince1970: Double(s)), watts: 110, targetWatts: 110) }
        let brief = RideCommentary.Brief(locale: "es", moment: .blockStart(1), workout: workout, ftp: 200, stepIndex: 1, elapsed: 308,
                                         intensityScale: 1.0, samples: samples, liveHeartRate: 140)
        XCTAssertEqual(brief.moment, "block_start")
        XCTAssertEqual(brief.previousBlock?.name, "Warm-up")
        XCTAssertEqual(brief.previousBlock?.avgWatts, 110)
        XCTAssertEqual(brief.currentBlock?.targetWatts, 200)
        XCTAssertEqual(brief.currentBlock?.zone.name, "Z4 threshold")
        XCTAssertEqual(brief.nextBlock?.name, "Cool-down")
        XCTAssertEqual(brief.nextBlock?.zone.name, "Z1 recovery")
        XCTAssertEqual(brief.remainingMinutes, 14)
        XCTAssertNil(brief.currentSoFar, "only mid-block cues carry the running block")

        // Intensity +10 % scales the targets the coach talks about.
        let harder = RideCommentary.Brief(locale: "en", moment: .blockStart(1), workout: workout, ftp: 200, stepIndex: 1, elapsed: 308, intensityScale: 1.1, samples: samples)
        XCTAssertEqual(harder.currentBlock?.targetWatts, 220)
        XCTAssertEqual(harder.intensityPercent, 110)

        let finish = RideCommentary.Brief(locale: "en", moment: .finish, workout: workout, ftp: 200, stepIndex: nil, elapsed: 1200, intensityScale: 1, samples: samples)
        XCTAssertEqual(finish.previousBlock?.name, "Cool-down")
        XCTAssertNil(finish.currentBlock)
        XCTAssertEqual(finish.rideSoFar?.avgWatts, 110)

        let text = try RideCommentary.userMessage(brief)
        XCTAssertTrue(text.contains("\"adaptation\":\"lactate clearance and FTP\""))
        XCTAssertTrue(RideCommentary.instructions(locale: "es").contains("JSON"))
    }

    func testParseTrimsLongLinesAndDefaultsMood() throws {
        let ok = try RideCommentary.parse(Data(#"{"caption":"Buen bloque: 198 W de media. Ahora 10 minutos a 200 W.","mood":"praise"}"#.utf8))
        XCTAssertEqual(ok.mood, .praise)
        XCTAssertEqual(ok.caption, "Buen bloque: 198 W de media. Ahora 10 minutos a 200 W.")

        let unknown = try RideCommentary.parse(Data(#"{"caption":"Steady.","mood":"ecstatic"}"#.utf8))
        XCTAssertEqual(unknown.mood, .steady)

        let long = String(repeating: "Keep this cadence smooth. ", count: 12)
        let cut = try RideCommentary.parse(Data(try JSONEncoder().encode(["caption": long])))
        XCTAssertLessThanOrEqual(cut.caption.count, RideCommentary.maxCaptionLength)
        XCTAssertTrue(cut.caption.hasSuffix("."), "cut at a sentence boundary, not mid-word")

        XCTAssertThrowsError(try RideCommentary.parse(Data(#"{"caption":"  ","mood":"push"}"#.utf8)))
    }

    func testCommentGoesThroughTheCoachInJSONMode() async throws {
        let answer = #"{"caption":"Warm-up done at 110 W. Ten minutes at 200 W now: this is where FTP is built.","mood":"push"}"#
        let sse = "data: {\"type\":\"response.completed\",\"response\":{\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\(try String(decoding: JSONEncoder().encode(answer), as: UTF8.self))}]}]}}\n"
        let t = FakeTransport(responses: [HTTPResponse(status: 200, body: Data(sse.utf8))])
        let coach = LLMCoach(transport: t, backend: .chatGPTPlan(accessToken: "tok"), model: "gpt-6-astra")
        let brief = RideCommentary.Brief(locale: "en", moment: .blockStart(1), workout: workout, ftp: 200, stepIndex: 1, elapsed: 308, intensityScale: 1, samples: [])
        let line = try await coach.comment(brief)
        XCTAssertEqual(line.mood, .push)
        let body = try JSONSerialization.jsonObject(with: t.requests[0].body!) as! [String: Any]
        XCTAssertTrue((body["instructions"] as! String).contains("loudspeaker"))
        XCTAssertTrue(((body["input"] as! [[String: Any]])[0]["content"] as! String).contains("\"moment\":\"block_start\""))
    }
}
