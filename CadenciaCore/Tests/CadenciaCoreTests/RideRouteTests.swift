import XCTest
@testable import CadenciaCore

final class RideRouteTests: XCTestCase {
    private var source: Data {
        let points = (0...2_000).map { "<trkpt lat=\"4.6\" lon=\"\(-74 + Double($0) * 0.00001)\"><ele>\(1000 + $0 / 5)</ele></trkpt>" }.joined()
        return Data("<gpx><trk><name>A &amp; B &lt;road&gt;</name><trkseg>\(points)</trkseg></trk><trk><name>Other</name><trkseg><trkpt lat=\"5\" lon=\"-74\"/><trkpt lat=\"5.1\" lon=\"-74\"/></trkseg></trk></gpx>".utf8)
    }

    func testNavigationExportRetainsSourceCoordinatesBeyondPreviewDownsampling() throws {
        let previews = try GPXImporter().parse(source)
        XCTAssertLessThan(previews[0].segments[0].count, 2_001)
        let exported = try GPXExporter.selectedRoute(from: source, index: 0)
        let restored = try GPXImporter().parse(exported, retainRawGeometry: true)
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored[0].segments[0].count, 2_001)
        XCTAssertEqual(restored[0].name, "A & B <road>")
        XCTAssertEqual(restored[0].distanceKm, previews[0].distanceKm, accuracy: 0.00001)
    }

    func testMultiRouteExportSelectsOnlyTheChosenCourse() throws {
        let exported = try GPXExporter.selectedRoute(from: source, index: 1)
        let route = try XCTUnwrap(GPXImporter().parse(exported).first)
        XCTAssertEqual(route.name, "Other")
        XCTAssertFalse(route.hasCompleteElevation)
        XCTAssertThrowsError(try GPXExporter.selectedRoute(from: source, index: 8))
    }

    func testRecordedActivityCombinesTracksWithoutDrawingAcrossTheirGap() throws {
        let routes = try GPXImporter().parse(source, combineTracks: true)
        XCTAssertEqual(routes.count, 1)
        XCTAssertEqual(routes[0].segments.count, 2)
        let separate = try GPXImporter().parse(source)
        XCTAssertEqual(routes[0].distanceKm, separate.map(\.distanceKm).reduce(0, +), accuracy: 0.00001)
    }

    func testFreeRideIsReviewableWithoutCompletingAnUnrelatedPrescription() throws {
        let session = PlannedSession(day: Day(year: 2026, month: 10, day: 30), kind: .endurance, title: "Monday", targetMinutes: 90,
                                     workout: Workout(name: "Endurance", kind: .endurance, steps: []), intervalsEventID: 42, location: .outdoor)
        let activity = ActivitySummary(id: "i100", name: "Free ride", type: "Ride", startDateLocal: session.day.date(), movingTime: 3_600)
        let ride = try XCTUnwrap(OutdoorRideImport.recording(activity: activity, sessions: [session], athleteID: "a1", fallbackFTP: 240))
        XCTAssertNil(ride.plannedSessionID)
        XCTAssertFalse(ride.completes(session))
        XCTAssertEqual(ride.sourceActivity?.id, "i100")
        XCTAssertTrue(ride.workout.steps.isEmpty)
        let brief = RideDebrief.Brief(locale: "en", ride: ride, ftp: 240)
        XCTAssertEqual(brief.unstructuredRide, true)
        XCTAssertEqual(brief.session.kind, "unstructured")
        XCTAssertTrue(brief.planned.isEmpty)
        XCTAssertNil(OutdoorRideImport.recording(activity: ActivitySummary(id: "v", name: "Virtual", type: "VirtualRide", startDateLocal: session.day.date(), movingTime: 60), sessions: [], athleteID: "a1", fallbackFTP: 240))
    }

    func testLaterExplicitPairingKeepsRecordedGPSAndCapturesPlannedRoute() throws {
        var session = PlannedSession(day: Day(year: 2026, month: 10, day: 30), kind: .endurance, title: "Monday", targetMinutes: 90,
                                     workout: Workout(name: "Endurance", kind: .endurance, steps: []), intervalsEventID: 42, location: .outdoor)
        session.route = try GPXImporter().parse(source).first
        var activity = ActivitySummary(id: "i100", name: "Free ride", type: "Ride", startDateLocal: session.day.date(), movingTime: 3_600)
        var existing = try XCTUnwrap(OutdoorRideImport.recording(activity: activity, sessions: [session], athleteID: "a1", fallbackFTP: 240))
        existing.recordedRoute = try GPXImporter().parse(source)[1]
        activity.pairedEventID = 42
        let updated = try XCTUnwrap(OutdoorRideImport.recording(activity: activity, sessions: [session], athleteID: "a1", fallbackFTP: 240, existing: existing))
        XCTAssertEqual(updated.id, existing.id)
        XCTAssertTrue(updated.completes(session))
        XCTAssertEqual(updated.recordedRoute, existing.recordedRoute)
        XCTAssertEqual(updated.plannedRoute, session.route)
        XCTAssertNotEqual(updated.plannedRoute?.id, updated.recordedRoute?.id)
        let briefData = try JSONEncoder().encode(RideDebrief.Brief(locale: "en", ride: updated, ftp: 240))
        let briefText = String(decoding: briefData, as: UTF8.self)
        XCTAssertTrue(briefText.contains("recordedCourse"))
        XCTAssertFalse(briefText.contains("latitude"))
        XCTAssertFalse(briefText.contains("profileSegments"))
        let json = try JSONEncoder().encode(updated)
        XCTAssertEqual(try JSONDecoder().decode(RideRecording.self, from: json), updated)
    }

    func testLegacySessionAndRideDecodeWithNoRouteAndCoachStaysCompact() throws {
        var session = PlannedSession(day: Day(year: 2026, month: 10, day: 30), kind: .endurance, title: "Monday", targetMinutes: 90)
        let legacy = try JSONEncoder().encode(session)
        XCTAssertNil(try JSONDecoder().decode(PlannedSession.self, from: legacy).route)
        session.route = try GPXImporter().parse(source).first
        let encoded = String(decoding: try JSONEncoder().encode(CoachBrief.PlannedRow(session)), as: UTF8.self)
        XCTAssertTrue(encoded.contains("routeDistanceKm"))
        XCTAssertFalse(encoded.contains("longitude"))
        XCTAssertFalse(encoded.contains("profileSegments"))
        XCTAssertLessThan(encoded.utf8.count, 5_000)
        let oldRide = RideRecording(athleteID: "a1", workout: Workout(name: "Indoor", kind: .endurance, steps: []), startedAt: session.day.date())
        XCTAssertNil(try JSONDecoder().decode(RideRecording.self, from: JSONEncoder().encode(oldRide)).recordedRoute)
    }

    func testRecordedGPXReadUsesOfficialEndpointAndNoSensorStreams() async throws {
        let transport = FakeTransport(responses: [HTTPResponse(status: 200, body: source)])
        let client = IntervalsClient(transport: transport, credential: .apiKey("test"))
        let data = try await client.activityGPX(id: "i100")
        XCTAssertEqual(data, source)
        XCTAssertEqual(transport.requests[0].method, .get)
        XCTAssertEqual(transport.requests[0].url.path, "/api/v1/activity/i100/gpx-file")
        XCTAssertEqual(transport.requests[0].url.query, "hr=false&power=false")
    }
}
