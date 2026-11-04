import XCTest
@testable import CadenciaCore

final class IntervalsDebriefTests: XCTestCase {
    private var ride: RideRecording {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        return RideRecording(athleteID: "athlete", workout: .init(name: "Short activation", kind: .openerActivation,
            steps: [.init(name: "Short effort", duration: 20, intensity: 1.1)]), startedAt: date,
            endedAt: date.addingTimeInterval(900), samples: [.init(time: date, watts: 9876, targetWatts: 9876)])
    }

    func testProviderAnalysisIsOnlySourceOfCompletedRideMeasurements() throws {
        let analysis = ActivityDetail(id: "i1", name: "Activity", analyzed: true, movingTime: 900, trainingLoad: 19,
            averageWatts: 117, normalizedWatts: 135, averageHR: 125, compliance: 98,
            intervals: [.init(id: 8, type: "WORK", startSeconds: 42, seconds: 20, averageWatts: 279)])
        let brief = RideDebrief.Brief(locale: "en", ride: ride, ftp: 250, analysis: analysis)
        let data = try JSONEncoder().encode(brief)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(brief.analysisSource, "intervals.icu")
        XCTAssertEqual(brief.intervals?.avgWatts, 117)
        XCTAssertEqual(brief.intervals?.intervals[0].avgWatts, 279)
        XCTAssertEqual(brief.intervals?.intervals[0].startSeconds, 42)
        XCTAssertEqual(brief.intervals?.intervals[0].seconds, 20)
        XCTAssertEqual(brief.planned[0].seconds, 20)
        XCTAssertNil(json["executed"])
        XCTAssertNil(json["totals"])
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("9876"), "phone metrics must not leak into the debrief")
    }

    func testPendingAnalysisCannotFallBackToPhoneMeasurementsOrCallCoach() async throws {
        for detail: ActivityDetail? in [nil, .init(id: "i1", name: "Pending", analyzed: false, movingTime: 900)] {
            let brief = RideDebrief.Brief(locale: "en", ride: ride, ftp: 250, analysis: detail)
            let transport = FakeTransport(responses: [])
            let coach = LLMCoach(transport: transport, endpoint: URL(string: "https://example.invalid/chat")!, apiKey: "test")
            XCTAssertNil(brief.intervals)
            XCTAssertNil(brief.session.riddenMinutes)
            do {
                _ = try await coach.debrief(brief)
                XCTFail("An unprocessed activity is not evidence for a debrief")
            } catch { XCTAssertEqual(error as? RideDebrief.AnalysisError, .notReady) }
            XCTAssertTrue(transport.requests.isEmpty)
        }
    }

    func testAggregateIntervalRemainsAggregateAndShortZoneExposureKeepsSeconds() throws {
        let analysis = ActivityDetail(id: "i1", name: "Activity", analyzed: true, movingTime: 900,
            powerZoneTimes: [.init(zone: "Z5", seconds: 18)], compliance: 100,
            intervals: [.init(id: 1, type: "RECOVERY", startSeconds: 0, seconds: 900, averageWatts: 117)])
        let brief = RideDebrief.Brief(locale: "en", ride: ride, ftp: 250, analysis: analysis)
        XCTAssertEqual(brief.intervals?.intervals.count, 1)
        XCTAssertEqual(brief.intervals?.intervals[0].seconds, 900)
        XCTAssertEqual(brief.intervals?.powerZoneSeconds[0].seconds, 18)
        XCTAssertEqual(brief.intervals?.compliancePercent, 100)
        XCTAssertTrue(RideDebrief.instructions(locale: "en").contains("cannot establish that a short planned effort was missed"))
    }
}
