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

struct ActivityDetailDTO: Decodable {
    struct ZoneTimeDTO: Decodable { let id: String?; let secs: Int? }
    struct HRRDTO: Decodable { let start_bpm: Int?; let end_bpm: Int?; let hrr: Int? }
    struct IntervalDTO: Decodable {
        let id: Int?
        let label: String?
        let type: String?
        let start_time: Int?
        let end_time: Int?
        let moving_time: Int?
        let elapsed_time: Int?
        let average_watts: Int?
        let weighted_average_watts: Int?
        let intensity: Int?
        let average_heartrate: Int?
        let max_heartrate: Int?
        let average_cadence: Double?
        let decoupling: Double?
        let zone: Int?
    }

    let id: String
    let name: String?
    let analyzed: String?
    let moving_time: Int?
    let elapsed_time: Int?
    let icu_training_load: Int?
    let icu_intensity: Double?
    let icu_average_watts: Int?
    let icu_weighted_avg_watts: Int?
    let average_heartrate: Int?
    let max_heartrate: Int?
    let average_cadence: Double?
    let icu_ftp: Int?
    let icu_pm_ftp: Int?
    let icu_joules: Int?
    let icu_joules_above_ftp: Int?
    let icu_zone_times: [ZoneTimeDTO]?
    let icu_hr_zone_times: [Int]?
    let icu_hrr: HRRDTO?
    let decoupling: Double?
    let icu_efficiency_factor: Double?
    let icu_variability_index: Double?
    let compliance: Double?
    let trimp: Double?
    let icu_ctl: Double?
    let icu_atl: Double?
    let icu_rpe: Int?
    let feel: Int?
    let calories: Int?
    let icu_intervals: [IntervalDTO]?

    var model: ActivityDetail {
        let hrr = icu_hrr.flatMap { h -> ActivityDetail.HRRecovery? in
            guard let s = h.start_bpm, let e = h.end_bpm else { return nil }
            return .init(startBPM: s, endBPM: e, drop: h.hrr ?? (s - e))
        }
        let intervals = (icu_intervals ?? []).enumerated().compactMap { i, d -> ActivityDetail.Interval? in
            guard let start = d.start_time else { return nil }
            let seconds = d.moving_time ?? d.elapsed_time ?? d.end_time.map { $0 - start } ?? 0
            return .init(id: d.id ?? i, label: d.label, type: d.type, startSeconds: start, seconds: seconds,
                         averageWatts: d.average_watts, normalizedWatts: d.weighted_average_watts, intensity: d.intensity,
                         averageHR: d.average_heartrate, maxHR: d.max_heartrate, averageCadence: d.average_cadence.map { Int($0.rounded()) },
                         decoupling: d.decoupling, zone: d.zone)
        }
        return ActivityDetail(id: id, name: name ?? "", analyzed: analyzed != nil, movingTime: TimeInterval(moving_time ?? elapsed_time ?? 0),
                              trainingLoad: icu_training_load, intensity: icu_intensity, averageWatts: icu_average_watts,
                              normalizedWatts: icu_weighted_avg_watts, averageHR: average_heartrate, maxHR: max_heartrate,
                              averageCadence: average_cadence.map { Int($0.rounded()) }, ftp: icu_ftp, estimatedFTP: icu_pm_ftp,
                              kilojoules: icu_joules.map { $0 / 1000 }, kilojoulesAboveFTP: icu_joules_above_ftp.map { $0 / 1000 },
                              powerZoneTimes: (icu_zone_times ?? []).compactMap { z in z.id.map { .init(zone: $0, seconds: z.secs ?? 0) } },
                              hrZoneTimes: icu_hr_zone_times ?? [], hrRecovery: hrr, decoupling: decoupling,
                              efficiencyFactor: icu_efficiency_factor, variabilityIndex: icu_variability_index, compliance: compliance,
                              trimp: trimp, ctl: icu_ctl, atl: icu_atl, rpe: icu_rpe, feel: feel, calories: calories, intervals: intervals)
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
    public var isCadenciaOwned: Bool { uid?.hasPrefix(PlanMirror.uidPrefix) == true }
}

/// How Cadencia's plan is mirrored to the Intervals calendar and kept to exactly one event per session.
///
/// Intervals counts every planned workout dated today in today's fitness, fatigue and form until midnight.
/// A reinstall or a rebuilt plan gives sessions new ids, so without cleanup each push would add another
/// planned workout on top of the old one and today's load would climb with every install.
public enum PlanMirror {
    public static let uidPrefix = "cadencia-"

    public static func uid(for session: PlannedSession) -> String { uidPrefix + session.id.uuidString.lowercased() }

    /// Cadencia-owned events that no session in the current plan accounts for. Other apps' and the
    /// athlete's own events are never touched.
    public static func staleEvents(_ events: [IntervalsEvent], sessions: [PlannedSession]) -> [IntervalsEvent] {
        let live = Set(sessions.map(uid(for:)))
        return events.filter { $0.isCadenciaOwned && !live.contains($0.uid ?? "") }
    }
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
