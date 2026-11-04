import XCTest
@testable import CadenciaCore

final class RouteGeometryTests: XCTestCase {
    func testInspectionInterpolatesDistanceAndElevationWithoutCrossingGaps() throws {
        let geometry = RouteGeometry([
            [RoutePoint(latitude: 4, longitude: -74, elevationM: 1_000, distanceKm: 0),
             RoutePoint(latitude: 4.1, longitude: -74, elevationM: 1_200, distanceKm: 10)],
            [RoutePoint(latitude: 5, longitude: -74, distanceKm: 12), RoutePoint(latitude: 5.1, longitude: -74, distanceKm: 22)]
        ])
        let point = try XCTUnwrap(geometry.point(at: 2.5))
        XCTAssertEqual(point.latitude, 4.025, accuracy: 0.00001)
        XCTAssertEqual(try XCTUnwrap(point.elevationM), 1_050, accuracy: 0.01)
        XCTAssertNil(geometry.point(at: 11))
        XCTAssertNil(geometry.point(at: -1))
        XCTAssertNil(geometry.point(at: .nan))
    }

    func testMapTapProjectsBetweenPointsAndDoesNotJoinRecordingGaps() throws {
        let geometry = RouteGeometry([
            [RoutePoint(latitude: 0, longitude: 0, distanceKm: 0), RoutePoint(latitude: 0, longitude: 0.1, distanceKm: 10)],
            [RoutePoint(latitude: 1, longitude: 0.1, distanceKm: 12), RoutePoint(latitude: 1, longitude: 0.2, distanceKm: 22)]
        ])
        let point = try XCTUnwrap(geometry.nearestPoint(latitude: 0.01, longitude: 0.025))
        XCTAssertEqual(point.distanceKm, 2.5, accuracy: 0.00001)
        XCTAssertEqual(point.latitude, 0)
        let gap = try XCTUnwrap(geometry.nearestPoint(latitude: 0.4, longitude: 0.1))
        XCTAssertEqual(gap.distanceKm, 10, accuracy: 0.00001)
        XCTAssertNil(point.elevationM)
    }

    func testMissingElevationIsNeverInterpolatedAsZero() throws {
        let geometry = RouteGeometry([[RoutePoint(latitude: 0, longitude: 0, elevationM: 500, distanceKm: 0),
                                       RoutePoint(latitude: 0, longitude: 0.1, distanceKm: 10)]])
        XCTAssertNil(geometry.point(at: 5)?.elevationM)
        XCTAssertEqual(geometry.point(at: 0)?.elevationM, 500)
        XCTAssertNil(RouteGeometry([]).nearestPoint(latitude: 0, longitude: 0))
    }

    func testDatelineInterpolationTakesTheShortRoute() throws {
        let geometry = RouteGeometry([[RoutePoint(latitude: 0, longitude: 179.9, distanceKm: 0),
                                       RoutePoint(latitude: 0, longitude: -179.9, distanceKm: 20)]])
        let midpoint = try XCTUnwrap(geometry.point(at: 10))
        XCTAssertEqual(abs(midpoint.longitude), 180, accuracy: 0.0001)
        let tapped = try XCTUnwrap(geometry.nearestPoint(latitude: 0.01, longitude: -179.95))
        XCTAssertEqual(tapped.distanceKm, 15, accuracy: 0.001)
    }
}
