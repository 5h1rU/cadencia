import Foundation

/// Coordinates and profile are kept locally; coaching briefs send only the course summary.
public struct RoutePoint: Codable, Equatable, Sendable {
    public var latitude: Double
    public var longitude: Double
    public var elevationM: Double?
    public var distanceKm: Double

    public init(latitude: Double, longitude: Double, elevationM: Double? = nil, distanceKm: Double = 0) {
        self.latitude = latitude; self.longitude = longitude
        self.elevationM = elevationM; self.distanceKm = distanceKm
    }
}

public enum ClimbCategory: String, Codable, CaseIterable, Sendable {
    case hc = "HC", one = "1", two = "2", three = "3", four = "4", uncategorized = "NC"

    /// Garmin Edge's documented geometric scoring scheme (August 2026). This is an estimate,
    /// not an organizer-assigned Tour/Giro category. Grade uses net rise over horizontal distance.
    public static func estimate(distanceKm: Double, averageGradient: Double) -> Self {
        guard distanceKm.isFinite, averageGradient.isFinite, distanceKm >= 0.5, averageGradient >= 3 else { return .uncategorized }
        let score = distanceKm * 1_000 * averageGradient
        if score > 80_000 { return .hc }
        if score > 64_000 { return .one }
        if score > 32_000 { return .two }
        if score > 16_000 { return .three }
        if score > 8_000 { return .four }
        return .uncategorized
    }
}

public struct ClimbProfilePoint: Codable, Equatable, Sendable {
    /// Absolute distance along the route; subtract the climb's start for a climb-local axis.
    public var distanceKm: Double
    public var altitudeM: Double
    public var latitude: Double
    public var longitude: Double
    public var gradientPercent: Double?
    /// Largest underlying spacing used here, so interpolation never masquerades as detailed data.
    public var sourceSpanM: Double
}

public struct ClimbSection: Codable, Equatable, Sendable {
    public var startKm: Double
    public var endKm: Double
    public var gainM: Double
    public var averageGradient: Double?
    public var distanceKm: Double { endKm - startKm }
}

public struct ClimbDetail: Codable, Equatable, Sendable {
    public var profile: [ClimbProfilePoint]
    public var kilometreSplits: [ClimbSection]
    public var steepest250m: ClimbSection?
    public var steepest1km: ClimbSection?
    public var hasDetailedGradients: Bool { profile.allSatisfy { $0.gradientPercent != nil } }
}

public struct RouteClimb: Codable, Equatable, Sendable, Identifiable {
    public var startKm: Double
    public var distanceKm: Double
    public var gainM: Double
    public var averageGradient: Double
    public var detail: ClimbDetail?
    public var id: String { "\(startKm):\(distanceKm)" }
    public var endKm: Double { startKm + distanceKm }
    public var category: ClimbCategory { .estimate(distanceKm: distanceKm, averageGradient: averageGradient) }

    public init(startKm: Double, distanceKm: Double, gainM: Double, averageGradient: Double, detail: ClimbDetail? = nil) {
        self.startKm = startKm; self.distanceKm = distanceKm; self.gainM = gainM
        self.averageGradient = averageGradient; self.detail = detail
    }
}

public struct GPXRoute: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    /// Separate segments must never be joined across recording gaps.
    public var segments: [[RoutePoint]]
    public var distanceKm: Double
    public var elevationGainM: Double?
    public var elevationLossM: Double?
    public var minAltitudeM: Double?
    public var maxAltitudeM: Double?
    public var elevationCoverage: Double
    public var climbs: [RouteClimb]
    public var profileSegments: [[ClimbProfilePoint]]?
    public var climbAnalysisVersion: Int?
    /// Older saved routes only retain simplified map geometry, never the original GPX detail.
    public var profileRebuiltFromCache: Bool?

    public var start: RoutePoint? { segments.first?.first }
    public var hasCompleteElevation: Bool { elevationCoverage == 1 }

    public func upgradingClimbAnalysis() throws -> GPXRoute {
        guard climbAnalysisVersion != ClimbAnalyzer.version || profileSegments == nil else { return self }
        let terrain = try ClimbAnalyzer().analyze(segments)
        var route = self
        route.climbs = terrain.climbs; route.profileSegments = terrain.profileSegments
        route.climbAnalysisVersion = ClimbAnalyzer.version; route.profileRebuiltFromCache = true
        return route
    }
}

public struct EventCourse: Codable, Equatable, Sendable {
    public enum Surface: String, Codable, CaseIterable, Sendable { case paved, gravel, trail, mixed }
    public enum TechnicalDifficulty: String, Codable, CaseIterable, Sendable { case low, moderate, high }
    /// These values are confirmed or corrected by the athlete. The original GPX metrics stay in `route`.
    public var elevationGainM: Double?
    public var elevationLossM: Double?
    public var startAltitudeM: Double?
    public var minAltitudeM: Double?
    public var maxAltitudeM: Double?
    public var surface: Surface?
    public var technicalDifficulty: TechnicalDifficulty?
    public var route: GPXRoute?
    public var sourceFileName: String?

    public init(elevationGainM: Double? = nil, elevationLossM: Double? = nil, startAltitudeM: Double? = nil,
                minAltitudeM: Double? = nil, maxAltitudeM: Double? = nil, surface: Surface? = nil,
                technicalDifficulty: TechnicalDifficulty? = nil, route: GPXRoute? = nil, sourceFileName: String? = nil) {
        self.elevationGainM = elevationGainM; self.elevationLossM = elevationLossM
        self.startAltitudeM = startAltitudeM; self.minAltitudeM = minAltitudeM; self.maxAltitudeM = maxAltitudeM
        self.surface = surface; self.technicalDifficulty = technicalDifficulty
        self.route = route; self.sourceFileName = sourceFileName
    }
}

public struct EventDetails: Codable, Equatable, Sendable {
    public enum Discipline: String, Codable, CaseIterable, Sendable { case road, gravel, mountainBike, timeTrial, other }
    public enum Goal: String, Codable, CaseIterable, Sendable { case finishComfortably, finishStrong, targetTime, compete }
    public var locationName: String?
    public var latitude: Double?
    public var longitude: Double?
    public var timeZoneIdentifier: String?
    /// Wall-clock HH:mm at the event location, independent of the athlete's device time zone.
    public var localStartTime: String?
    public var discipline: Discipline?
    public var goal: Goal?
    public var expectedDurationMinutes: Int?
    public var cutoffMinutes: Int?
    public var usualAltitudeM: Double?
    public var arrivalDay: Day?
    /// Rider expectations, never presented as a weather forecast.
    public var expectedTemperatureC: Double?
    public var expectedHumidityPercent: Double?
    public var conditionsNote: String?
    public var terrainExperience: String?
    public var supportNotes: String?
    public var trainingConstraints: String?

    public init() {}
}
