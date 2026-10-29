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
