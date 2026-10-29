import Foundation

// Wire formats for Intervals.icu. Field names match the OpenAPI spec at https://intervals.icu/api/v1/docs.
// Everything is optional: the API omits fields freely and we never want a missing field to fail a sync.

struct AthleteDTO: Decodable {
    struct SportSettingsDTO: Decodable {
        let types: [String]?
        let ftp: Int?
        let indoor_ftp: Int?
        let lthr: Int?
        let max_hr: Int?
        let power_zones: [Int]?
    }
    let id: String
    let name: String?
    let firstname: String?
    let lastname: String?
    let weight: Double?
    let icu_weight: Double?
    let timezone: String?
    let sportSettings: [SportSettingsDTO]?

    var profile: AthleteProfile {
        let ride = sportSettings?.first { ($0.types ?? []).contains("Ride") } ?? sportSettings?.first
        let displayName = name ?? [firstname, lastname].compactMap { $0 }.joined(separator: " ")
        return AthleteProfile(id: id, name: displayName, ftp: ride?.ftp, indoorFTP: ride?.indoor_ftp,
                              weightKg: icu_weight ?? weight, maxHR: ride?.max_hr, lthr: ride?.lthr,
                              powerZones: ride?.power_zones ?? [], timezone: timezone)
    }
}

struct WellnessDTO: Decodable {
    let id: String
    let ctl: Double?
    let atl: Double?
    let weight: Double?
    let restingHR: Int?
    let hrv: Double?
    let hrvSDNN: Double?
    let sleepSecs: Int?
    let readiness: Double?
    let soreness: Int?
    let fatigue: Int?
    let updated: String?

    var model: WellnessDay? {
        guard let day = Day(iso: id) else { return nil }
        return WellnessDay(day: day, hrvMs: hrv ?? hrvSDNN, restingHR: restingHR, sleepSeconds: sleepSecs, ctl: ctl, atl: atl,
                           weightKg: weight, readinessReported: readiness, soreness: soreness, fatigue: fatigue,
                           updatedAt: updated.flatMap(IntervalsDates.parseDateTime))
    }
}

struct ActivityDTO: Decodable {
    let id: String
    let name: String?
    let type: String?
    let start_date_local: String?
    let moving_time: Int?
    let elapsed_time: Int?
    let distance: Double?
    let icu_training_load: Int?
    let icu_intensity: Double?
    let icu_average_watts: Int?
    let icu_weighted_avg_watts: Int?
    let average_heartrate: Int?
    let icu_ftp: Int?
    let icu_pm_ftp: Int?
    let icu_rpe: Int?
    let feel: Int?
    let trainer: Bool?
    let external_id: String?
    let paired_event_id: Int?

    var model: ActivitySummary? {
        guard let start = start_date_local.flatMap(IntervalsDates.parseLocalDateTime) else { return nil }
        return ActivitySummary(id: id, name: name ?? "", type: type ?? "Ride", startDateLocal: start,
                               movingTime: TimeInterval(moving_time ?? elapsed_time ?? 0), distanceMeters: distance,
                               trainingLoad: icu_training_load, intensity: icu_intensity, averageWatts: icu_average_watts,
                               normalizedWatts: icu_weighted_avg_watts, averageHR: average_heartrate, ftpAtTime: icu_ftp,
                               estimatedFTP: icu_pm_ftp, rpe: icu_rpe, feel: feel, isTrainer: trainer ?? false,
                               externalID: external_id, pairedEventID: paired_event_id)
    }
}

struct PowerCurvesDTO: Decodable {
    struct Curve: Decodable {
        let secs: [Int]?
        let values: [Double]?
    }
    let list: [Curve]?

    var points: [PowerCurvePoint] {
        guard let c = list?.first, let secs = c.secs, let values = c.values else { return [] }
        return zip(secs, values).map { PowerCurvePoint(seconds: $0, watts: Int($1.rounded())) }
    }
}

/// A calendar event as Intervals returns it. Kept close to the wire so the sync layer can reconcile by `uid`/`external_id`.
public struct IntervalsEvent: Decodable, Equatable, Sendable, Identifiable {
    public let id: Int
    public let uid: String?
    public let external_id: String?
    public let category: String?
    public let name: String?
    public let description: String?
    public let start_date_local: String?
    public let type: String?
    public let moving_time: Int?
    public let icu_training_load: Int?

    public var day: Day? { start_date_local.flatMap { Day(iso: $0) } }
    public var isCadenciaOwned: Bool { uid?.hasPrefix("cadencia-") == true }
}

enum IntervalsDates {
    /// Intervals' `start_date_local` is "yyyy-MM-dd'T'HH:mm:ss" in the athlete's local timezone, no offset.
    static func parseLocalDateTime(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f.date(from: String(s.prefix(19)))
    }

    /// `updated` fields are ISO 8601 with fractional seconds and an offset like "+0000".
    static func parseDateTime(_ s: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        return f.date(from: s)
    }
}
