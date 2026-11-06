import Foundation

// Intervals.icu is the source of truth for everything it has a native field for. This file maps Cadencia's
// values onto those fields and back. Field names follow https://intervals.icu/api/v1/docs.

// MARK: - OAuth scopes

/// Intervals OAuth scopes are `AREA:READ` or `AREA:WRITE`; WRITE implies READ. The athlete can untick
/// scopes on the consent screen, so every write checks what was actually granted.
public enum IntervalsScope: String, CaseIterable, Sendable {
    case activityWrite = "ACTIVITY:WRITE"
    case wellnessWrite = "WELLNESS:WRITE"
    case calendarWrite = "CALENDAR:WRITE"
    case settingsWrite = "SETTINGS:WRITE"
    case chatsWrite = "CHATS:WRITE"

    var area: Substring { rawValue.split(separator: ":")[0] }
}

public extension IntervalsCredential {
    /// API keys can do everything the athlete can. OAuth tokens only what was granted.
    func grants(_ scope: IntervalsScope) -> Bool {
        switch self {
        case .apiKey: return true
        case .oauth(_, let scopes): return scopes.contains { $0.uppercased() == scope.rawValue }
        }
    }

    /// Scopes Cadencia asks for but this token lacks. Non-empty means the athlete must reconnect, which
    /// is how tokens issued before Cadencia wrote wellness and settings get the new scopes.
    var missingScopes: [IntervalsScope] {
        IntervalsOAuth.defaultScopes.compactMap(IntervalsScope.init(rawValue:)).filter { !grants($0) }
    }
}

// MARK: - Wellness

/// Intervals' subjective wellness fields are 1…4 where 1 is good and 4 is bad (soreness 1 = not sore,
/// motivation 1 = extreme, sleep quality 1 = great). Sending -1 clears a field.
public enum IntervalsWellnessScale {
    public static let clear = -1

    /// Legs are muscular: they live in `soreness`.
    public static func soreness(for legs: SubjectiveFeedback.Legs) -> Int {
        switch legs { case .fresh: return 1; case .ok: return 2; case .heavy: return 3 }
    }

    /// From `soreness`, else `fatigue` when only that was recorded (for example in the Intervals app).
    public static func legs(soreness: Int?, fatigue: Int?) -> SubjectiveFeedback.Legs? {
        switch soreness ?? fatigue {
        case 1: return .fresh
        case 2: return .ok
        case 3, 4: return .heavy
        default: return nil
        }
    }

    /// Cadencia's 1 (low) … 5 (high) to Intervals' 1 (high) … 4 (low).
    public static func intervals(fromFivePoint value: Int) -> Int {
        switch value {
        case ...1: return 4
        case 2: return 4
        case 3: return 3
        case 4: return 2
        default: return 1
        }
    }

    /// Intervals' 1 (high) … 4 (low) to Cadencia's 1 (low) … 5 (high).
    public static func fivePoint(fromIntervals value: Int) -> Int? {
        switch value {
        case 1: return 5
        case 2: return 4
        case 3: return 3
        case 4: return 2
        default: return nil
        }
    }
}

/// The fields of one day's wellness record Cadencia writes. Nil fields are not sent, so values other
/// sources wrote stay. `PUT /api/v1/athlete/{id}/wellness/{date}` changes only the fields provided.
public struct WellnessUpdate: Codable, Equatable, Sendable {
    public var day: Day
    public var weightKg: Double?
    public var soreness: Int?
    public var fatigue: Int?
    public var sleepQuality: Int?
    public var motivation: Int?
    public var mood: Int?
    public var stress: Int?
    public var injury: Int?
    public var comments: String?
    public var hrvMs: Double?
    public var restingHR: Int?
    public var sleepSeconds: Int?

    public init(day: Day, weightKg: Double? = nil, soreness: Int? = nil, fatigue: Int? = nil, sleepQuality: Int? = nil,
                motivation: Int? = nil, mood: Int? = nil, stress: Int? = nil, injury: Int? = nil, comments: String? = nil,
                hrvMs: Double? = nil, restingHR: Int? = nil, sleepSeconds: Int? = nil) {
        self.day = day; self.weightKg = weightKg; self.soreness = soreness; self.fatigue = fatigue
        self.sleepQuality = sleepQuality; self.motivation = motivation; self.mood = mood; self.stress = stress
        self.injury = injury; self.comments = comments; self.hrvMs = hrvMs; self.restingHR = restingHR; self.sleepSeconds = sleepSeconds
    }

    /// The wellness fields this feedback has a native home for. `rpe` belongs to the activity, not here.
    public init(feedback: SubjectiveFeedback) {
        self.init(day: feedback.day)
        soreness = feedback.legs.map(IntervalsWellnessScale.soreness(for:))
        sleepQuality = feedback.sleepQuality.map(IntervalsWellnessScale.intervals(fromFivePoint:))
        motivation = feedback.motivation.map(IntervalsWellnessScale.intervals(fromFivePoint:))
        mood = feedback.mood.flatMap(Self.rating)
        stress = feedback.stress.flatMap(Self.rating)
        injury = feedback.injury.flatMap(Self.rating)
        comments = feedback.note.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
    }

    /// Only what changed between two versions of a day's feedback. A field that was set and is now empty is
    /// cleared in Intervals (-1 for numbers, an empty comment), so the athlete's correction sticks there too.
    public init(changingFrom old: SubjectiveFeedback?, to new: SubjectiveFeedback) {
        let before = old.map(WellnessUpdate.init(feedback:)) ?? WellnessUpdate(day: new.day)
        let after = WellnessUpdate(feedback: new)
        func diff(_ a: Int?, _ b: Int?) -> Int? { a == b ? nil : (b ?? IntervalsWellnessScale.clear) }
        self.init(day: new.day)
        soreness = diff(before.soreness, after.soreness)
        sleepQuality = diff(before.sleepQuality, after.sleepQuality)
        motivation = diff(before.motivation, after.motivation)
        mood = diff(before.mood, after.mood)
        stress = diff(before.stress, after.stress)
        injury = diff(before.injury, after.injury)
        comments = before.comments == after.comments ? nil : (after.comments ?? "")
    }

    /// Recovery values read from Apple Health.
    public init(health day: WellnessDay) {
        self.init(day: day.day, weightKg: day.weightKg, hrvMs: day.hrvMs, restingHR: day.restingHR, sleepSeconds: day.sleepSeconds)
    }

    private static func rating(_ v: Int) -> Int? { (1...4).contains(v) ? v : nil }

    public var isEmpty: Bool { self == WellnessUpdate(day: day) }

    /// Later non-nil values win; a pending update absorbs newer edits of the same day.
    public func merging(_ newer: WellnessUpdate) -> WellnessUpdate {
        var m = self
        m.weightKg = newer.weightKg ?? weightKg
        m.soreness = newer.soreness ?? soreness
        m.fatigue = newer.fatigue ?? fatigue
        m.sleepQuality = newer.sleepQuality ?? sleepQuality
        m.motivation = newer.motivation ?? motivation
        m.mood = newer.mood ?? mood
        m.stress = newer.stress ?? stress
        m.injury = newer.injury ?? injury
        m.comments = newer.comments ?? comments
        m.hrvMs = newer.hrvMs ?? hrvMs
        m.restingHR = newer.restingHR ?? restingHR
        m.sleepSeconds = newer.sleepSeconds ?? sleepSeconds
        return m
    }

    /// Intervals' JSON field names. `id` is the day, as `wellness-bulk` requires.
    public var body: [String: Any] {
        var b: [String: Any] = ["id": day.iso]
        if let v = weightKg { b["weight"] = v }
        if let v = soreness { b["soreness"] = v }
        if let v = fatigue { b["fatigue"] = v }
        if let v = sleepQuality { b["sleepQuality"] = v }
        if let v = motivation { b["motivation"] = v }
        if let v = mood { b["mood"] = v }
        if let v = stress { b["stress"] = v }
        if let v = injury { b["injury"] = v }
        if let v = comments { b["comments"] = v }
        if let v = hrvMs { b["hrv"] = v }
        if let v = restingHR { b["restingHR"] = v }
        if let v = sleepSeconds { b["sleepSecs"] = v }
        return b
    }

    /// Whether `day` already holds every value this update would write (so it can be dropped).
    public func isReflected(in day: WellnessDay) -> Bool {
        func same(_ a: Double?, _ b: Double?) -> Bool { a.map { a in b.map { abs(a - $0) < 0.05 } ?? false } ?? true }
        func same<T: Equatable>(_ a: T?, _ b: T?) -> Bool { a == nil || a == b }
        return same(weightKg, day.weightKg) && same(soreness, day.soreness) && same(fatigue, day.fatigue)
            && same(sleepQuality, day.sleepQuality) && same(motivation, day.motivation) && same(mood, day.mood)
            && same(stress, day.stress) && same(injury, day.injury) && same(comments, day.comments)
            && same(hrvMs, day.hrvMs) && same(restingHR, day.restingHR) && same(sleepSeconds, day.sleepSeconds)
    }
}

public extension SubjectiveFeedback {
    /// Intervals' view of the day, keeping what only lives elsewhere (`rpe`, on the activity) from `cached`.
    /// A field cleared in Intervals is cleared here: Intervals wins.
    init?(wellness day: WellnessDay, cached: SubjectiveFeedback? = nil) {
        let legs = IntervalsWellnessScale.legs(soreness: day.soreness, fatigue: day.fatigue)
        let sleep = day.sleepQuality.flatMap(IntervalsWellnessScale.fivePoint(fromIntervals:))
        let motivation = day.motivation.flatMap(IntervalsWellnessScale.fivePoint(fromIntervals:))
        guard legs != nil || sleep != nil || motivation != nil || day.mood != nil || day.stress != nil
                || day.injury != nil || day.comments != nil || cached?.rpe != nil else { return nil }
        self.init(day: day.day, rpe: cached?.rpe, legs: legs, sleepQuality: sleep, motivation: motivation,
                  note: day.comments, mood: day.mood, stress: day.stress, injury: day.injury)
    }

    /// Lays a pending (unsent) update over what Intervals returned, so a local edit survives a refresh
    /// that ran before it reached Intervals.
    func applying(_ pending: WellnessUpdate) -> SubjectiveFeedback {
        var f = self
        func rating(_ v: Int) -> Int? { (1...4).contains(v) ? v : nil } // -1 clears
        if let v = pending.soreness { f.legs = IntervalsWellnessScale.legs(soreness: v, fatigue: nil) }
        if let v = pending.sleepQuality { f.sleepQuality = IntervalsWellnessScale.fivePoint(fromIntervals: v) }
        if let v = pending.motivation { f.motivation = IntervalsWellnessScale.fivePoint(fromIntervals: v) }
        if let v = pending.mood { f.mood = rating(v) }
        if let v = pending.stress { f.stress = rating(v) }
        if let v = pending.injury { f.injury = rating(v) }
        if let v = pending.comments { f.note = v.isEmpty ? nil : v }
        return f
    }
}

// MARK: - Athlete and sport settings

public enum IntervalsAthleteFields {
    public static let metric = "meters"
    public static let imperial = "feet"

    /// Intervals keeps the athlete's height in metres.
    public static func heightCm(fromMeters meters: Double) -> Double? {
        guard meters.isFinite, meters > 0 else { return nil }
        return (meters * 1000).rounded() / 10
    }

    public static func meters(fromCm cm: Double) -> Double { (cm * 10).rounded() / 1000 }

    public static func measurementPreference(metric: Bool) -> String { metric ? Self.metric : imperial }

    /// Nil for a value Cadencia does not recognise, so it never flips the setting by guessing.
    public static func isMetric(_ preference: String?) -> Bool? {
        switch preference?.lowercased() {
        case Self.metric: return true
        case Self.imperial: return false
        default: return nil
        }
    }

    /// The Ride sport settings body for an FTP the athlete accepted in Cadencia. Cadencia's working FTP is
    /// the indoor FTP when Intervals has one, so that one changes too; otherwise only `ftp` is written.
    public static func rideFTPBody(ftp: Int, athlete: AthleteProfile?) -> [String: Any] {
        var body: [String: Any] = ["ftp": ftp]
        if athlete?.indoorFTP != nil { body["indoor_ftp"] = ftp }
        return body
    }

    /// Whether Intervals already holds this accepted FTP (so the pending write can be dropped).
    public static func holds(ftp: Int, athlete: AthleteProfile?) -> Bool {
        guard let athlete else { return false }
        return athlete.ftp == ftp && (athlete.indoorFTP == nil || athlete.indoorFTP == ftp)
    }

    /// The athlete's cached profile after a successful FTP write.
    public static func applying(ftp: Int, to athlete: AthleteProfile) -> AthleteProfile {
        var a = athlete
        a.ftp = ftp
        if a.indoorFTP != nil { a.indoorFTP = ftp }
        return a
    }
}

// MARK: - Training availability

/// One entry of the athlete's `training_availability` (default weekly availability).
///
/// Unverified without a real account: `day_of_week` is taken as ISO-8601 (1 = Monday … 7 = Sunday, Java's
/// `DayOfWeek`), and `max_training_time` as seconds like every other Intervals duration.
public struct IntervalsAvailabilityDay: Codable, Equatable, Sendable {
    public enum Level: String, Codable, Sendable { case normal = "NORMAL", limited = "LIMITED", unavailable = "UNAVAILABLE" }
    public var day_of_week: Int
    public var training_availability: Level
    public var max_training_time: Int?
    public var can_train_sports: [String]?

    public init(dayOfWeek: Int, level: Level, maxTrainingSeconds: Int? = nil, sports: [String]? = nil) {
        day_of_week = dayOfWeek; training_availability = level; max_training_time = maxTrainingSeconds; can_train_sports = sports
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        day_of_week = try c.decode(Int.self, forKey: .day_of_week)
        training_availability = (try? c.decode(Level.self, forKey: .training_availability)) ?? .normal
        max_training_time = try c.decodeIfPresent(Int.self, forKey: .max_training_time)
        can_train_sports = try c.decodeIfPresent([String].self, forKey: .can_train_sports)
    }

    var body: [String: Any] {
        var b: [String: Any] = ["day_of_week": day_of_week, "training_availability": training_availability.rawValue]
        if let v = max_training_time { b["max_training_time"] = v }
        if let v = can_train_sports { b["can_train_sports"] = v }
        return b
    }
}

public enum IntervalsAvailability {
    /// Cadencia weekdays are 1 = Sunday … 7 = Saturday (`Calendar`); Intervals' are ISO 1 = Monday … 7 = Sunday.
    public static func isoDay(fromWeekday weekday: Int) -> Int { weekday == 1 ? 7 : weekday - 1 }
    public static func weekday(fromISODay day: Int) -> Int? { (1...7).contains(day) ? (day == 7 ? 1 : day + 1) : nil }

    public static let cyclingSports = ["Ride", "VirtualRide"]

    /// All seven days: a riding day is LIMITED to its minutes, other days are UNAVAILABLE for riding.
    /// `otherSports` (by Cadencia weekday) lists the extra sport types a day holds, such as WeightTraining.
    public static func days(from availability: Availability, otherSports: [Int: [String]] = [:]) -> [IntervalsAvailabilityDay] {
        (1...7).map { iso in
            let weekday = weekday(fromISODay: iso)!
            let others = otherSports[weekday] ?? []
            if let minutes = availability.minutesByWeekday[weekday], minutes > 0 {
                return IntervalsAvailabilityDay(dayOfWeek: iso, level: .limited, maxTrainingSeconds: minutes * 60,
                                                sports: cyclingSports + others.filter { !cyclingSports.contains($0) })
            }
            if !others.isEmpty { return IntervalsAvailabilityDay(dayOfWeek: iso, level: .limited, sports: others) }
            return IntervalsAvailabilityDay(dayOfWeek: iso, level: .unavailable)
        }
    }

    /// Sport types per Cadencia weekday from the plan's other training.
    public static func otherSports(_ training: [PlanConsultation.OtherTraining]) -> [Int: [String]] {
        var byDay: [Int: [String]] = [:]
        for activity in training {
            let type = CalendarEntry.sportType(for: activity.name)
            for weekday in activity.weekdays where !(byDay[weekday] ?? []).contains(type) { byDay[weekday, default: []].append(type) }
        }
        return byDay
    }

    /// Intervals' availability laid over the plan's. A day Intervals marks unavailable, or whose sports
    /// exclude cycling, has no riding; a LIMITED day with a time gets exactly that time; NORMAL keeps
    /// Cadencia's minutes. The long-ride day and per-day session types have no Intervals field and stay.
    public static func applying(_ days: [IntervalsAvailabilityDay], to availability: Availability) -> Availability {
        var result = availability
        for entry in days {
            guard let weekday = weekday(fromISODay: entry.day_of_week) else { continue }
            let ridesAllowed = entry.can_train_sports.map { $0.contains { cyclingSports.contains($0) || $0.hasSuffix("Ride") } } ?? true
            switch entry.training_availability {
            case .unavailable:
                result.minutesByWeekday[weekday] = nil
            case _ where !ridesAllowed:
                result.minutesByWeekday[weekday] = nil
            case .limited:
                if let seconds = entry.max_training_time, seconds >= 60 { result.minutesByWeekday[weekday] = seconds / 60 }
            case .normal:
                // Also what an athlete who never set availability has: no information, nothing changes.
                break
            }
        }
        if result.minutesByWeekday != availability.minutesByWeekday {
            result.hoursPerWeek = min(availability.hoursPerWeek, Double(result.minutesByWeekday.values.reduce(0, +)) / 60)
        }
        return result
    }

    /// The consultation's weekly rides after Intervals' availability: dropped days go, capped days shrink.
    /// The session type of each day stays Cadencia's.
    public static func applying(_ availability: Availability, to rides: [PlanConsultation.WeeklyRide]) -> [PlanConsultation.WeeklyRide] {
        rides.compactMap { ride in
            guard let minutes = availability.minutesByWeekday[ride.weekday] else { return nil }
            var r = ride
            r.minutes = minutes
            return r
        }
    }
}
