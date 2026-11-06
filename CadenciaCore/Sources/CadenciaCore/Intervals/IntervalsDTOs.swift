import Foundation

/// An activity note, as returned by Intervals' messages endpoint. Deleted notes never count as synced.
public struct IntervalsActivityNote: Codable, Equatable, Sendable, Identifiable {
    public static let coachPrefix = "Cadencia · Coach\n\n"
    public var id: Int64
    public var content: String
    public var deleted: String?

    public init(id: Int64, content: String, deleted: String? = nil) {
        self.id = id; self.content = content; self.deleted = deleted
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int64.self, forKey: .id)
        content = try c.decodeIfPresent(String.self, forKey: .content) ?? ""
        deleted = try c.decodeIfPresent(String.self, forKey: .deleted)
    }

    public var isCoachDebrief: Bool { deleted == nil && content.hasPrefix(Self.coachPrefix) }
    public var debriefText: String { isCoachDebrief ? String(content.dropFirst(Self.coachPrefix.count)) : content }
}

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
    let height: Double?
    let measurement_preference: String?
    let training_availability: [IntervalsAvailabilityDay]?

    var profile: AthleteProfile {
        let ride = sportSettings?.first { ($0.types ?? []).contains("Ride") } ?? sportSettings?.first
        let displayName = name ?? [firstname, lastname].compactMap { $0 }.joined(separator: " ")
        return AthleteProfile(id: id, name: displayName, ftp: ride?.ftp, indoorFTP: ride?.indoor_ftp,
                              weightKg: icu_weight ?? weight, maxHR: ride?.max_hr, lthr: ride?.lthr,
                              powerZones: ride?.power_zones ?? [], timezone: timezone,
                              heightCm: height.flatMap(IntervalsAthleteFields.heightCm(fromMeters:)),
                              measurementPreference: measurement_preference,
                              trainingAvailability: training_availability.flatMap { $0.isEmpty ? nil : $0 })
    }
}

struct WellnessDTO: Decodable {
    struct SportInfoDTO: Decodable { let type: String?; let eftp: Double? }
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
    let sleepQuality: Int?
    let motivation: Int?
    let mood: Int?
    let stress: Int?
    let injury: Int?
    let comments: String?
    let updated: String?
    let sportInfo: [SportInfoDTO]?

    var model: WellnessDay? {
        guard let day = Day(iso: id) else { return nil }
        // Intervals' scale is 1…4; anything else (including -1, "unset") reads as no answer.
        func rating(_ v: Int?) -> Int? { v.flatMap { (1...4).contains($0) ? $0 : nil } }
        return WellnessDay(day: day, hrvMs: hrv ?? hrvSDNN, restingHR: restingHR, sleepSeconds: sleepSecs, ctl: ctl, atl: atl,
                           weightKg: weight, readinessReported: readiness, soreness: rating(soreness), fatigue: rating(fatigue),
                           updatedAt: updated.flatMap(IntervalsDates.parseDateTime),
                           estimatedFTP: sportInfo?.first { $0.type == "Ride" }?.eftp,
                           sleepQuality: rating(sleepQuality), motivation: rating(motivation), mood: rating(mood),
                           stress: rating(stress), injury: rating(injury),
                           comments: comments.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 })
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
    let total_elevation_gain: Double?
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
    let compliance: Double?
    let icu_rolling_ftp: Int?

    var model: ActivitySummary? {
        guard let start = start_date_local.flatMap(IntervalsDates.parseLocalDateTime) else { return nil }
        return ActivitySummary(id: id, name: name ?? "", type: type ?? "Ride", startDateLocal: start,
                               movingTime: TimeInterval(moving_time ?? elapsed_time ?? 0), distanceMeters: distance,
                               trainingLoad: icu_training_load, intensity: icu_intensity, averageWatts: icu_average_watts,
                               normalizedWatts: icu_weighted_avg_watts, averageHR: average_heartrate, ftpAtTime: icu_ftp,
                               estimatedFTP: icu_pm_ftp, rpe: icu_rpe, feel: feel, isTrainer: trainer ?? false,
                               externalID: external_id, pairedEventID: paired_event_id, elevationGainMeters: total_elevation_gain,
                               compliance: compliance, rollingFTP: icu_rolling_ftp)
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
public struct IntervalsEvent: Codable, Equatable, Sendable, Identifiable {
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
    // Optional native fields Cadencia reads back so edits made in Intervals win.
    public let end_date_local: String?
    public let indoor: Bool?
    public let icu_ftp: Int?
    public let tags: [String]?
    /// Metres.
    public let distance: Double?
    public let training_availability: String?

    public var day: Day? { start_date_local.flatMap { Day(iso: $0) } }
    /// Last day the event covers. Cadencia writes the inclusive last day; a missing end is a one-day event.
    public var endDay: Day? { end_date_local.flatMap { Day(iso: $0) } ?? day }

    /// One of Cadencia's planned rides (current day-based ids or legacy session-UUID ids). Cadencia's
    /// other calendar entries (`CalendarEntry`) share the "cadencia-" prefix but are not plan sessions.
    public var isCadenciaOwned: Bool {
        PlanMirror.isSessionIdentifier(uid) || PlanMirror.isSessionIdentifier(external_id)
    }

    public var trainingEvent: TrainingEvent? {
        guard let day, let name, !name.isEmpty else { return nil }
        let priority: TrainingEvent.Priority
        switch category {
        case "RACE_A": priority = .a
        case "RACE_B": priority = .b
        case "RACE_C": priority = .c
        default: return nil
        }
        let isRace = !(tags ?? []).contains(CalendarEntry.notRaceTag)
        return TrainingEvent(name: name, day: day, distanceKm: distance.flatMap { $0 > 0 ? $0 / 1000 : nil },
                             priority: priority, objective: description ?? "", isRace: isRace)
    }
}

/// How Cadencia's plan is mirrored to the Intervals calendar and kept to exactly one event per session.
///
/// Intervals counts every planned workout dated today in today's fitness, fatigue and form until midnight.
/// A reinstall or a rebuilt plan gives sessions new ids, so without cleanup each push would add another
/// planned workout on top of the old one and today's load would climb with every install. Cadencia keeps at
/// most one planned ride per day, so the identity is the day itself: `cadencia-ride-YYYY-MM-DD`. Earlier
/// versions used the session UUID (`cadencia-<uuid>`, or the bare UUID); those copies are still recognised.
public enum PlanMirror {
    public static let uidPrefix = "cadencia-"
    public static let sessionPrefix = "cadencia-ride-"

    public static func externalID(for day: Day) -> String { sessionPrefix + day.iso }
    public static func externalID(for session: PlannedSession) -> String { session.externalID ?? externalID(for: session.day) }
    /// Same as the external id, so a create with `upsertOnUid` also lands on the day's existing event.
    public static func uid(for session: PlannedSession) -> String { externalID(for: session) }
    static func legacyID(for session: PlannedSession) -> String { uidPrefix + session.id.uuidString.lowercased() }

    /// A planned-ride identifier: the day-based form or any other "cadencia-" id that is not one of
    /// Cadencia's other calendar entries (legacy session UUIDs).
    public static func isSessionIdentifier(_ value: String?) -> Bool {
        guard let value, value.hasPrefix(uidPrefix) else { return false }
        return value.hasPrefix(sessionPrefix) || !CalendarEntry.isEntryIdentifier(value)
    }

    public static func matches(_ event: IntervalsEvent, session: PlannedSession) -> Bool {
        let current = externalID(for: session), legacy = legacyID(for: session)
        return event.id == session.intervalsEventID || event.uid == current || event.external_id == current
            || event.uid == legacy || event.external_id == legacy
            || event.external_id?.lowercased() == session.id.uuidString.lowercased()
    }

    /// Prefer the recorded server id; otherwise keep the newest copy of this known session.
    public static func existingEvent(for session: PlannedSession, in events: [IntervalsEvent]) -> IntervalsEvent? {
        let candidates = events.filter { matches($0, session: session) }
        return candidates.first { $0.id == session.intervalsEventID } ?? candidates.max { $0.id < $1.id }
    }

    /// Cadencia-owned planned rides that no session in the current plan accounts for. Other apps' and the
    /// athlete's own events, and Cadencia's non-ride calendar entries, are never touched.
    public static func staleEvents(_ events: [IntervalsEvent], sessions: [PlannedSession]) -> [IntervalsEvent] {
        let keep = Set(sessions.compactMap { existingEvent(for: $0, in: events)?.id })
        return events.filter { event in
            let owned = event.isCadenciaOwned || sessions.contains { matches(event, session: $0) }
            return owned && !keep.contains(event.id)
        }
    }

    /// External ids of days whose planned ride is gone: the retired days minus any day that has a session
    /// again. Safe for `bulk-delete` by external id because the id names the whole day.
    public static func retiredExternalIDs(days: [Day], keeping sessions: [PlannedSession]) -> [String] {
        let kept = Set(sessions.map(\.day))
        return Set(days.filter { !kept.contains($0) }).sorted().map(externalID(for:))
    }

    // MARK: Native fields

    /// The planned-ride fields Intervals has natively: `indoor`, `icu_ftp` (the FTP the indoor targets are
    /// a percentage of) and a `tags` entry with the `SessionKind`.
    public struct NativeFields: Codable, Equatable, Sendable {
        public var indoor: Bool
        /// Indoor sessions only; an outdoor event's `icu_ftp` is the outdoor FTP its watts were scaled to.
        public var ftp: Int?
        public var kind: SessionKind
        public init(indoor: Bool, ftp: Int?, kind: SessionKind) { self.indoor = indoor; self.ftp = ftp; self.kind = kind }
    }

    /// What `IntervalsClient.upsertPlannedWorkout` writes for this session with `ftp` as the target FTP.
    public static func nativeFields(for session: PlannedSession, ftp: Int) -> NativeFields {
        let indoor = session.location != .outdoor
        return NativeFields(indoor: indoor, ftp: indoor ? (session.prescriptionFTP ?? ftp) : nil, kind: session.kind)
    }

    public static func eventFTP(for session: PlannedSession, ftp: Int) -> Int {
        session.location == .outdoor ? ftp : (session.prescriptionFTP ?? ftp)
    }

    public static func tags(for kind: SessionKind) -> [String] { [kind.rawValue] }

    static func kind(fromTags tags: [String]?) -> SessionKind? {
        tags?.lazy.compactMap { SessionKind(rawValue: $0) }.first
    }

    /// Folds edits made to this session's event in Intervals back into the session. Only fields Cadencia
    /// has not changed since its last write are adopted, so an unsent local change is never lost.
    /// Returns whether anything changed.
    @discardableResult
    public static func adopt(_ event: IntervalsEvent, into session: inout PlannedSession) -> Bool {
        guard let mirrored = session.mirrored, matches(event, session: session),
              session.status != .completed, session.status != .skipped else { return false }
        let localIndoor = session.location != .outdoor
        let localFTP = localIndoor ? (session.prescriptionFTP ?? mirrored.ftp) : nil
        guard localIndoor == mirrored.indoor, localFTP == mirrored.ftp, session.kind == mirrored.kind else { return false }
        let indoor = event.indoor ?? mirrored.indoor
        let remote = NativeFields(indoor: indoor, ftp: indoor ? (event.icu_ftp ?? mirrored.ftp) : nil,
                                  kind: kind(fromTags: event.tags) ?? mirrored.kind)
        guard remote != mirrored else { return false }
        session.location = remote.indoor ? .indoor : .outdoor
        if remote.indoor, let ftp = remote.ftp { session.prescriptionFTP = ftp }
        // A rest day stays a rest day: the calendar never turns a planned rest into riding.
        if remote.kind != .rest, mirrored.kind != .rest { session.kind = remote.kind }
        session.mirrored = remote
        return true
    }

    /// An activity Intervals paired with this session's event completes it; its compliance comes along.
    /// Nil when nothing is paired. Never un-completes a session completed on this phone.
    public static func completion(for session: PlannedSession, activities: [ActivitySummary]) -> Double?? {
        guard let id = session.intervalsEventID,
              let activity = activities.first(where: { $0.pairedEventID == id }) else { return nil }
        return .some(activity.compliance)
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
