import XCTest
@testable import CadenciaCore

final class ClimbAnalysisTests: XCTestCase {
    private func points(_ knots: [(Double, Double)]) -> [RoutePoint] {
        var result: [RoutePoint] = []
        for (a, b) in zip(knots, knots.dropFirst()) {
            let steps = max(1, Int(((b.0 - a.0) / 0.025).rounded()))
            for index in 0..<steps {
                let fraction = Double(index) / Double(steps), km = a.0 + (b.0 - a.0) * fraction
                result.append(RoutePoint(latitude: 4.6 + km / 111, longitude: -74.08,
                                         elevationM: a.1 + (b.1 - a.1) * fraction, distanceKm: km))
            }
        }
        if let last = knots.last { result.append(RoutePoint(latitude: 4.6 + last.0 / 111, longitude: -74.08, elevationM: last.1, distanceKm: last.0)) }
        return result
    }

    func testCategoryEligibilityAndEveryDocumentedBoundary() {
        XCTAssertEqual(ClimbCategory.estimate(distanceKm: 0.499, averageGradient: 20), .uncategorized)
        XCTAssertEqual(ClimbCategory.estimate(distanceKm: 40, averageGradient: 2.99), .uncategorized)
        XCTAssertEqual(ClimbCategory.estimate(distanceKm: 0.5, averageGradient: 20), .four)
        for (grade, expected) in [(8.0, ClimbCategory.uncategorized), (8.01, .four), (16, .four), (16.01, .three),
                                  (32, .three), (32.01, .two), (64, .two), (64.01, .one), (80, .one), (80.01, .hc)] {
            XCTAssertEqual(ClimbCategory.estimate(distanceKm: 1, averageGradient: grade), expected)
        }
        XCTAssertEqual(ClimbCategory.estimate(distanceKm: .nan, averageGradient: 7), .uncategorized)
        XCTAssertEqual(ClimbCategory.estimate(distanceKm: 10, averageGradient: .infinity), .uncategorized)
    }

    func testShortFlatAndDipRemainInsideOneClimb() throws {
        let terrain = try ClimbAnalyzer().analyze([points([(0, 1_000), (1, 1_080), (1.2, 1_080), (1.35, 1_070), (2, 1_150), (3, 1_200)])])
        let climb = try XCTUnwrap(terrain.climbs.first)
        XCTAssertEqual(terrain.climbs.count, 1)
        XCTAssertEqual(climb.startKm, 0, accuracy: 0.03)
        XCTAssertEqual(climb.endKm, 3, accuracy: 0.03)
        XCTAssertEqual(climb.averageGradient, 200 / 30, accuracy: 0.1)
        XCTAssertGreaterThan(climb.gainM, 200, "total ascent includes regaining elevation after the relief section")
        XCTAssertTrue(climb.detail?.profile.contains { ($0.gradientPercent ?? 0) < 0 } == true)
    }

    func testMeaningfulDescentSeparatesTwoClimbs() throws {
        let terrain = try ClimbAnalyzer().analyze([points([(0, 1_000), (1, 1_100), (1.6, 1_000), (2.6, 1_120)])])
        XCTAssertEqual(terrain.climbs.count, 2)
        XCTAssertLessThan(terrain.climbs[0].endKm, terrain.climbs[1].startKm)
        XCTAssertEqual(terrain.climbs[1].startKm, 1.6, accuracy: 0.05)
    }

    func testLongPlateauEndsAClimbBeforeTheNextAscent() throws {
        let terrain = try ClimbAnalyzer().analyze([points([(0, 1_000), (1, 1_100), (2, 1_100), (3, 1_200)])])
        XCTAssertEqual(terrain.climbs.count, 2)
        XCTAssertEqual(terrain.climbs[0].endKm, 1, accuracy: 0.05)
        XCTAssertEqual(terrain.climbs[1].startKm, 2, accuracy: 0.05)
    }

    func testRecordingAndMissingElevationGapsAreNeverMerged() throws {
        let a = points([(0, 1_000), (1, 1_100)]), b = points([(1.2, 1_200), (2.2, 1_300)])
        XCTAssertEqual(try ClimbAnalyzer().analyze([a, b]).climbs.count, 2)
        let missing = RoutePoint(latitude: 4.61, longitude: -74.08, elevationM: nil, distanceKm: 1.1)
        let terrain = try ClimbAnalyzer().analyze([a + [missing] + b])
        XCTAssertEqual(terrain.climbs.count, 2)
        XCTAssertEqual(terrain.profileSegments.count, 2)
    }

    func testDetailedProfileFindsSustainedRampsAndKilometreSplits() throws {
        let terrain = try ClimbAnalyzer().analyze([points([(0, 1_000), (1, 1_040), (2, 1_110), (3, 1_230), (4, 1_260), (5, 1_310), (6, 1_390)])])
        let climb = try XCTUnwrap(terrain.climbs.first), detail = try XCTUnwrap(climb.detail)
        XCTAssertEqual(climb.category, .two)
        XCTAssertEqual(climb.averageGradient, 6.5, accuracy: 0.05)
        XCTAssertEqual(detail.kilometreSplits.count, 6)
        XCTAssertEqual(try XCTUnwrap(detail.steepest250m?.averageGradient), 12, accuracy: 0.1)
        XCTAssertEqual(try XCTUnwrap(detail.steepest1km?.averageGradient), 12, accuracy: 0.2)
        XCTAssertEqual(try XCTUnwrap(detail.steepest1km?.startKm), 2, accuracy: 0.05)
        XCTAssertTrue(detail.hasDetailedGradients)
        let sample = try XCTUnwrap(ProfileSampler(detail.profile).point(at: 2.5))
        XCTAssertEqual(sample.altitudeM, 1_170, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(sample.gradientPercent), 12, accuracy: 0.1)
        XCTAssertNil(ProfileSampler(detail.profile).point(at: 7))
    }

    func testSparseGPXHasAnOverallCategoryButNoInventedLocalGradients() throws {
        let terrain = try ClimbAnalyzer().analyze([[RoutePoint(latitude: 4.6, longitude: -74.08, elevationM: 1_000, distanceKm: 0),
                                                   RoutePoint(latitude: 4.65, longitude: -74.08, elevationM: 1_400, distanceKm: 6)]])
        let climb = try XCTUnwrap(terrain.climbs.first), detail = try XCTUnwrap(climb.detail)
        XCTAssertEqual(climb.category, .two)
        XCTAssertFalse(detail.hasDetailedGradients)
        XCTAssertNil(detail.steepest250m)
        XCTAssertNil(detail.steepest1km)
        XCTAssertTrue(detail.kilometreSplits.allSatisfy { $0.averageGradient == nil })
    }

    func testProfilesAndLegacyClimbsRemainCodableAndCoachPayloadStaysCompact() throws {
        let xml = "<gpx><trk><trkseg>" + (0...2_000).map { i in
            "<trkpt lat=\"0\" lon=\"\(Double(i) * 0.000225)\"><ele>\(1_000 + i)</ele></trkpt>"
        }.joined() + "</trkseg></trk></gpx>"
        let route = try XCTUnwrap(GPXImporter().parse(Data(xml.utf8)).first)
        XCTAssertGreaterThan(route.profileSegments?.flatMap { $0 }.count ?? 0, route.segments.flatMap { $0 }.count)
        XCTAssertEqual(try JSONDecoder().decode(GPXRoute.self, from: JSONEncoder().encode(route)), route)
        let legacy = try JSONDecoder().decode(RouteClimb.self, from: Data("{\"startKm\":0,\"distanceKm\":6,\"gainM\":400,\"averageGradient\":6.666}".utf8))
        XCTAssertNil(legacy.detail)
        XCTAssertEqual(legacy.category, .two)
        let event = TrainingEvent(name: "Fondo", day: Day(year: 2027, month: 1, day: 1), course: EventCourse(route: route))
        let data = try JSONEncoder().encode(CoachBrief.Event(event, today: event.day))
        let encoded = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(encoded.contains("estimatedCategory"))
        XCTAssertFalse(encoded.contains("profile"))
        XCTAssertFalse(encoded.contains("latitude"))
        XCTAssertLessThan(data.count, 10_000)
    }

    func testSavedPreviewCanUpgradeOnceWithoutChangingConfirmedMetrics() throws {
        let xml = "<gpx><rte><rtept lat=\"0\" lon=\"0\"><ele>1000</ele></rtept><rtept lat=\"0\" lon=\"0.06\"><ele>1400</ele></rtept></rte></gpx>"
        var route = try XCTUnwrap(GPXImporter().parse(Data(xml.utf8)).first)
        route.profileSegments = nil; route.climbAnalysisVersion = nil
        let upgraded = try route.upgradingClimbAnalysis()
        XCTAssertEqual(upgraded.id, route.id)
        XCTAssertEqual(upgraded.distanceKm, route.distanceKm)
        XCTAssertEqual(upgraded.elevationGainM, route.elevationGainM)
        XCTAssertEqual(upgraded.profileRebuiltFromCache, true)
        XCTAssertNotNil(upgraded.climbs.first?.detail)
        XCTAssertEqual(try upgraded.upgradingClimbAnalysis(), upgraded)
    }
}
