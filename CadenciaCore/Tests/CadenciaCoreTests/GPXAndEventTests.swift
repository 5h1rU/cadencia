import XCTest
@testable import CadenciaCore

final class GPXImporterTests: XCTestCase {
    func parse(_ body: String) throws -> [GPXRoute] {
        try GPXImporter().parse(Data(("<gpx version=\"1.1\" xmlns=\"http://www.topografix.com/GPX/1/1\">" + body + "</gpx>").utf8))
    }
    func point(_ lon: Double, elevation: Double? = nil) -> String {
        "<trkpt lat=\"0\" lon=\"\(lon)\">" + (elevation.map { "<ele>\($0)</ele>" } ?? "") + "</trkpt>"
    }

    func testTrackGeometryDistanceAndAltitudeAreCalculatedSeparately() throws {
        let route = try XCTUnwrap(parse("<trk><name>Race &amp; climb</name><trkseg>" + point(0, elevation: 2_000) + point(0.01, elevation: 2_100) + point(0.02, elevation: 2_050) + "</trkseg></trk>").first)
        XCTAssertEqual(route.name, "Race & climb")
        XCTAssertEqual(route.distanceKm, 2.2239, accuracy: 0.001)
        XCTAssertEqual(route.elevationGainM, 100)
        XCTAssertEqual(route.elevationLossM, 50)
        XCTAssertEqual(route.minAltitudeM, 2_000)
        XCTAssertEqual(route.maxAltitudeM, 2_100)
        XCTAssertEqual(route.start?.elevationM, 2_000)
        XCTAssertEqual(route.climbs.count, 1)
        XCTAssertEqual(route.climbs[0].distanceKm, 1.11195, accuracy: 0.001)
        XCTAssertEqual(route.climbs[0].averageGradient, 8.993, accuracy: 0.01)
    }

    func testRecordingGapsDoNotAddDistanceOrElevation() throws {
        let route = try XCTUnwrap(parse("<trk><trkseg>" + point(0, elevation: 0) + point(0.01, elevation: 10)
            + "</trkseg><trkseg>" + point(50, elevation: 3_000) + point(50.01, elevation: 3_010) + "</trkseg></trk>").first)
        XCTAssertEqual(route.distanceKm, 2.2239, accuracy: 0.001)
        XCTAssertEqual(route.elevationGainM, 20)
        XCTAssertEqual(route.segments.count, 2)
    }

    func testMissingElevationStaysUnknownWithoutInventingRangeOrClimbing() throws {
        let route = try XCTUnwrap(parse("<trk><trkseg>" + point(0, elevation: 2_500) + point(0.01) + point(0.02, elevation: 2_900) + "</trkseg></trk>").first)
        XCTAssertNil(route.elevationGainM)
        XCTAssertNil(route.elevationLossM)
        XCTAssertNil(route.maxAltitudeM)
        XCTAssertNil(route.minAltitudeM)
        XCTAssertFalse(route.hasCompleteElevation)
        XCTAssertTrue(route.climbs.isEmpty)
        XCTAssertEqual(route.start?.elevationM, 2_500)
    }

    func testElevationNoiseDoesNotBecomeRepeatedClimbing() throws {
        let points = (0..<20).map { point(Double($0) * 0.001, elevation: Double(100 + $0 % 2)) }.joined()
        let route = try XCTUnwrap(parse("<trk><trkseg>\(points)</trkseg></trk>").first)
        XCTAssertEqual(route.elevationGainM, 0)
        XCTAssertEqual(route.elevationLossM, 0)
        XCTAssertTrue(route.hasCompleteElevation)
    }

    func testGradualClimbStartsAtItsElevationAnchor() throws {
        let points = (0...100).map { point(Double($0) * 0.0001, elevation: Double($0)) }.joined()
        let route = try XCTUnwrap(parse("<trk><trkseg>\(points)</trkseg></trk>").first)
        XCTAssertEqual(route.climbs.first?.startKm, 0)
        XCTAssertEqual(try XCTUnwrap(route.climbs.first?.distanceKm), route.distanceKm, accuracy: 0.001)
    }

    func testRoutesAndTracksRemainSeparateChoicesAndWaypointsAreNotRoutes() throws {
        let routes = try parse("""
        <wpt lat="0" lon="0"><name>Parking</name></wpt>
        <rte><name>Short</name><rtept lat="0" lon="0"/><rtept lat="0" lon="0.01"/></rte>
        <trk><name>Long</name><trkseg>\(point(0))\(point(0.02))</trkseg></trk>
        """)
        XCTAssertEqual(routes.count, 2)
        XCTAssertEqual(routes.map(\.name), ["Short", "Long"])
        XCTAssertEqual(routes[1].distanceKm, routes[0].distanceKm * 2, accuracy: 0.001)
        XCTAssertNil(routes[0].elevationGainM)
    }

    func testGPX10AndPrefixedNamespacesAreSupported() throws {
        let data = Data("""
        <g:gpx xmlns:g="http://www.topografix.com/GPX/1/0" version="1.0">
        <g:rte><g:rtept lat="4" lon="-74"><g:ele>-20</g:ele></g:rtept>
        <g:rtept lat="4.01" lon="-74"><g:ele>-10</g:ele></g:rtept></g:rte></g:gpx>
        """.utf8)
        let route = try XCTUnwrap(GPXImporter().parse(data).first)
        XCTAssertEqual(route.elevationGainM, 10)
        XCTAssertEqual(route.minAltitudeM, -20)
    }

    func testInvalidFilesAndCoordinatesAreRejected() {
        for body in ["<trk>", "<wpt lat=\"0\" lon=\"0\"/>", "<rte><rtept lat=\"91\" lon=\"0\"/><rtept lat=\"0\" lon=\"0\"/></rte>", "<rte><rtept lat=\"nan\" lon=\"0\"/></rte>"] {
            XCTAssertThrowsError(try parse(body))
        }
        XCTAssertThrowsError(try GPXImporter().parse(Data("<!DOCTYPE gpx [<!ENTITY x 'abc'>]><gpx/>".utf8)))
        let utf16 = "<?xml version=\"1.0\" encoding=\"UTF-16\"?><!DOCTYPE gpx [<!ENTITY x 'abc'>]><gpx/>".data(using: .utf16)!
        XCTAssertThrowsError(try GPXImporter().parse(utf16))
        XCTAssertThrowsError(try GPXImporter().parse(Data(repeating: 0, count: GPXImporter.maximumBytes + 1)))
    }

    func testDisplaySamplingPreservesFullDistanceAndBothEndpoints() throws {
        let points = (0...2_000).map { point(Double($0) * 0.00001, elevation: Double($0)) }.joined()
        let route = try XCTUnwrap(parse("<trk><trkseg>\(points)</trkseg></trk>").first)
        XCTAssertLessThanOrEqual(route.segments[0].count, 1_001)
        XCTAssertEqual(route.segments[0].first?.longitude, 0)
        XCTAssertEqual(route.segments[0].last?.longitude, 0.02)
        XCTAssertEqual(route.distanceKm, 2.2239, accuracy: 0.001)
    }

    private func denseRouteData() -> Data {
        let points = (0...10_000).map { point(Double($0) * 0.00001, elevation: Double($0 % 300)) }.joined()
        return Data("<gpx><trk><trkseg>\(points)</trkseg></trk></gpx>".utf8)
    }

    func testProgressReportsMeasuredBytesThenPointsWithoutGoingBackwards() throws {
        let data = denseRouteData()
        let log = GPXProgressLog()
        let routes = try GPXImporter().parse(data) { log.append($0) }
        XCTAssertEqual(routes.count, 1)
        let parsing = log.values.filter { $0.stage == .parsing }
        let analyzing = log.values.filter { $0.stage == .analyzing }
        XCTAssertEqual(parsing.first?.completedUnits, 0)
        XCTAssertEqual(parsing.last?.completedUnits, data.count)
        XCTAssertEqual(parsing.last?.totalUnits, data.count)
        XCTAssertTrue(parsing.contains { $0.fractionCompleted > 0 && $0.fractionCompleted < 1 })
        XCTAssertEqual(analyzing.last?.completedUnits, 10_001)
        XCTAssertEqual(analyzing.last?.totalUnits, 10_001)
        XCTAssertTrue(analyzing.contains { $0.fractionCompleted > 0 && $0.fractionCompleted < 1 })
        for stage in [parsing, analyzing] {
            XCTAssertTrue(stage.allSatisfy { (0...1).contains($0.fractionCompleted) })
            XCTAssertTrue(zip(stage, stage.dropFirst()).allSatisfy { $0.fractionCompleted <= $1.fractionCompleted })
        }
    }

    func testCancellationWhileParsingStopsTheImport() async {
        let data = denseRouteData()
        let task = Task.detached {
            try GPXImporter().parse(data) { update in
                if update.stage == .parsing && update.completedUnits > 0 {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
        }
        do { _ = try await task.value; XCTFail("A cancelled import must not return a route") }
        catch is CancellationError {}
        catch { XCTFail("Expected cancellation, got \(error)") }
    }

    func testCancellationWhileAnalyzingStopsTheImport() async {
        let data = denseRouteData()
        let task = Task.detached {
            try GPXImporter().parse(data) { update in
                if update.stage == .analyzing && update.completedUnits > 0 {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
        }
        do { _ = try await task.value; XCTFail("A cancelled calculation must not return a route") }
        catch is CancellationError {}
        catch { XCTFail("Expected cancellation, got \(error)") }
    }
}

private final class GPXProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [GPXImporter.ProgressUpdate] = []
    var values: [GPXImporter.ProgressUpdate] { lock.lock(); defer { lock.unlock() }; return storage }
    func append(_ update: GPXImporter.ProgressUpdate) { lock.lock(); defer { lock.unlock() }; storage.append(update) }
}

final class EventCoursePlanningTests: XCTestCase {
    let start = Day(year: 2026, month: 11, day: 2)
    func event() throws -> TrainingEvent {
        let route = try XCTUnwrap(GPXImporter().parse(Data("<gpx><rte><rtept lat=\"4\" lon=\"-74\"><ele>2000</ele></rtept><rtept lat=\"4.1\" lon=\"-74\"><ele>2500</ele></rtept></rte></gpx>".utf8)).first)
        var details = EventDetails()
        details.locationName = "Bogotá"; details.latitude = 4; details.longitude = -74
        details.timeZoneIdentifier = "America/Bogota"; details.localStartTime = "06:30"
        details.discipline = .road; details.goal = .finishStrong; details.expectedDurationMinutes = 360
        details.usualAltitudeM = 1_000; details.arrivalDay = start.adding(days: 53)
        details.expectedTemperatureC = 16; details.trainingConstraints = "Indoor trainer on weekdays"
        return TrainingEvent(name: "Mountain fondo", day: start.adding(days: 55), distanceKm: 120, isRace: true,
                             course: EventCourse(elevationGainM: 2_000, startAltitudeM: 2_000, maxAltitudeM: 2_500,
                                                 surface: .paved, route: route, sourceFileName: "fondo.gpx"), details: details)
    }

    func testLegacyEventAndPlanStillDecodeWithoutNewKeys() throws {
        let legacy = TrainingEvent(name: "Old fondo", day: start.adding(days: 55), distanceKm: 100)
        let data = try JSONEncoder().encode(legacy)
        let restored = try JSONDecoder().decode(TrainingEvent.self, from: data)
        XCTAssertNil(restored.course); XCTAssertNil(restored.details)
        let plan = PlanBuilder().build(.init(goal: .event, startDay: start, endDay: legacy.day, event: legacy, availability: .typical))
        XCTAssertEqual(try JSONDecoder().decode(TrainingPlan.self, from: JSONEncoder().encode(plan)), plan)
    }

    func testRouteAndConfirmedOverridesPersistAndReachCompactCoachBrief() throws {
        let event = try event()
        let restored = try JSONDecoder().decode(TrainingEvent.self, from: JSONEncoder().encode(event))
        XCTAssertEqual(restored, event)
        let brief = CoachBrief.Event(restored, today: start)
        XCTAssertEqual(brief.course?.elevationGainM, 2_000, "confirmed figures override the GPX estimate")
        XCTAssertEqual(brief.details?.usualAltitudeM, 1_000)
        XCTAssertEqual(brief.details?.timeZoneIdentifier, "America/Bogota")
        XCTAssertNil(brief.details?.latitude)
        let text = String(decoding: try JSONEncoder().encode(brief), as: UTF8.self)
        XCTAssertFalse(text.contains("segments"), "route geometry must not inflate coaching requests")
        XCTAssertFalse(text.contains("sourceFileName"))
    }

    func testClimbingEventPlanRespectsRecoveryAndUsesExpectedEventDuration() throws {
        let event = try event()
        let plan = PlanBuilder().build(.init(goal: .event, startDay: start, endDay: event.day, event: event, availability: .typical))
        XCTAssertTrue(plan.sessions.contains { plan.phase(for: $0.day)?.focus == .build && $0.kind == .threshold })
        XCTAssertFalse(plan.sessions.contains { plan.weekNumber(of: $0.day) == 4 && $0.kind.isHard })
        XCTAssertEqual(plan.sessions.first { $0.day == event.day }?.targetMinutes, 360)
        XCTAssertEqual(plan.event?.course, event.course)
        let prompt = LLMCoach.systemPrompt(context: CoachContext(today: start, plan: plan))
        XCTAssertTrue(prompt.contains("usualAltitudeM"))
        XCTAssertTrue(prompt.contains("2000"))
    }

    func testEventIsScheduledEvenOnAnUnavailableTrainingWeekday() throws {
        var event = try event()
        event.day = start.adding(days: 53) // Friday, unavailable in the typical training week.
        let plan = PlanBuilder().build(.init(goal: .event, startDay: start, endDay: event.day, event: event, availability: .typical))
        let session = try XCTUnwrap(plan.sessions.first { $0.day == event.day })
        XCTAssertEqual(session.kind, .race)
        XCTAssertEqual(session.targetMinutes, 360)
        XCTAssertTrue(session.isPriority)
        XCTAssertFalse(plan.sessions.contains { $0.day.weekday() == 6 && $0.day != event.day })
    }
}
