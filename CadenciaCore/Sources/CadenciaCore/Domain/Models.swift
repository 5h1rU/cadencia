import Foundation

// MARK: - Calendar day

/// A local calendar day (no time, no timezone). Intervals.icu uses yyyy-MM-dd local dates everywhere.
public struct Day: Hashable, Codable, Comparable, Sendable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    public init(_ date: Date, calendar: Calendar = .current) {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: c.year!, month: c.month!, day: c.day!)
    }

    public init?(iso: String) {
        let parts = iso.prefix(10).split(separator: "-")
        guard parts.count == 3, let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
        self.init(year: y, month: m, day: d)
    }

    public var iso: String { String(format: "%04d-%02d-%02d", year, month, day) }
    public var description: String { iso }

    public func date(calendar: Calendar = .current) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    public func adding(days: Int, calendar: Calendar = .current) -> Day {
        Day(calendar.date(byAdding: .day, value: days, to: date(calendar: calendar))!, calendar: calendar)
    }

    public func days(until other: Day, calendar: Calendar = .current) -> Int {
        calendar.dateComponents([.day], from: date(calendar: calendar), to: other.date(calendar: calendar)).day!
    }

    /// 1 = Sunday … 7 = Saturday, matching `Calendar.component(.weekday)`.
    public func weekday(calendar: Calendar = .current) -> Int {
        calendar.component(.weekday, from: date(calendar: calendar))
    }

    /// Monday of the week containing this day.
    public func startOfWeek(calendar: Calendar = .current) -> Day {
        let wd = weekday(calendar: calendar) // 1=Sun
        let offset = (wd + 5) % 7 // Mon=0 … Sun=6
        return adding(days: -offset, calendar: calendar)
    }

    public static func < (lhs: Day, rhs: Day) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let d = Day(iso: s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid day \(s)"))
        }
        self = d
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(iso)
    }
}

// MARK: - Athlete

public struct AthleteProfile: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var ftp: Int?
    public var indoorFTP: Int?
    public var weightKg: Double?
    public var maxHR: Int?
    public var lthr: Int?
    public var powerZones: [Int] // upper bound of each zone as % of FTP, Intervals convention
    public var timezone: String?

    public init(id: String, name: String, ftp: Int? = nil, indoorFTP: Int? = nil, weightKg: Double? = nil,
                maxHR: Int? = nil, lthr: Int? = nil, powerZones: [Int] = [], timezone: String? = nil) {
        self.id = id
        self.name = name
        self.ftp = ftp
        self.indoorFTP = indoorFTP
        self.weightKg = weightKg
        self.maxHR = maxHR
        self.lthr = lthr
        self.powerZones = powerZones
        self.timezone = timezone
    }

    /// FTP used for prescriptions: indoor FTP when set, otherwise outdoor.
    public var workingFTP: Int? { indoorFTP ?? ftp }
}

// MARK: - Wellness

/// One day of recovery signals, merged from Intervals.icu and Apple Health.
public struct WellnessDay: Codable, Equatable, Sendable, Identifiable {
    public var id: Day { day }
    public var day: Day
    public var hrvMs: Double?          // rMSSD or SDNN depending on source; we keep one series per athlete
    public var restingHR: Int?
    public var sleepSeconds: Int?
    public var ctl: Double?
    public var atl: Double?
    public var weightKg: Double?
    public var readinessReported: Double?
    public var soreness: Int?          // 1 (none) … 4 (very sore), Intervals scale
    public var fatigue: Int?
    public var updatedAt: Date?

    public init(day: Day, hrvMs: Double? = nil, restingHR: Int? = nil, sleepSeconds: Int? = nil,
                ctl: Double? = nil, atl: Double? = nil, weightKg: Double? = nil, readinessReported: Double? = nil,
                soreness: Int? = nil, fatigue: Int? = nil, updatedAt: Date? = nil) {
        self.day = day
        self.hrvMs = hrvMs
        self.restingHR = restingHR
        self.sleepSeconds = sleepSeconds
        self.ctl = ctl
        self.atl = atl
        self.weightKg = weightKg
        self.readinessReported = readinessReported
        self.soreness = soreness
        self.fatigue = fatigue
        self.updatedAt = updatedAt
    }

    /// Training Stress Balance (form) = CTL − ATL.
    public var tsb: Double? {
        guard let ctl, let atl else { return nil }
        return ctl - atl
    }

    /// Overlay another source on top of this one. Non-nil values of `other` win.
    public func merging(_ other: WellnessDay) -> WellnessDay {
        var m = self
        m.hrvMs = other.hrvMs ?? hrvMs
        m.restingHR = other.restingHR ?? restingHR
        m.sleepSeconds = other.sleepSeconds ?? sleepSeconds
        m.ctl = other.ctl ?? ctl
        m.atl = other.atl ?? atl
        m.weightKg = other.weightKg ?? weightKg
        m.readinessReported = other.readinessReported ?? readinessReported
        m.soreness = other.soreness ?? soreness
        m.fatigue = other.fatigue ?? fatigue
        m.updatedAt = [updatedAt, other.updatedAt].compactMap { $0 }.max()
        return m
    }
}

// MARK: - Activities

public struct ActivitySummary: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var type: String                // "Ride", "VirtualRide", "Run", "WeightTraining"…
    public var startDateLocal: Date
    public var movingTime: TimeInterval
    public var distanceMeters: Double?
    public var trainingLoad: Int?
    public var intensity: Double?          // IF × 100
    public var averageWatts: Int?
    public var normalizedWatts: Int?
    public var averageHR: Int?
    public var ftpAtTime: Int?
    public var estimatedFTP: Int?           // Intervals' eFTP for the activity, when it produced one
    public var rpe: Int?                    // 1…10
    public var feel: Int?                   // 1 (strong) … 5 (weak), Intervals scale
    public var isTrainer: Bool
    public var externalID: String?
    public var pairedEventID: Int?

    public init(id: String, name: String, type: String, startDateLocal: Date, movingTime: TimeInterval,
                distanceMeters: Double? = nil, trainingLoad: Int? = nil, intensity: Double? = nil,
                averageWatts: Int? = nil, normalizedWatts: Int? = nil, averageHR: Int? = nil, ftpAtTime: Int? = nil,
                estimatedFTP: Int? = nil, rpe: Int? = nil, feel: Int? = nil, isTrainer: Bool = false,
                externalID: String? = nil, pairedEventID: Int? = nil) {
        self.id = id
        self.name = name
        self.type = type
        self.startDateLocal = startDateLocal
        self.movingTime = movingTime
        self.distanceMeters = distanceMeters
        self.trainingLoad = trainingLoad
        self.intensity = intensity
        self.averageWatts = averageWatts
        self.normalizedWatts = normalizedWatts
        self.averageHR = averageHR
        self.ftpAtTime = ftpAtTime
        self.estimatedFTP = estimatedFTP
        self.rpe = rpe
        self.feel = feel
        self.isTrainer = isTrainer
        self.externalID = externalID
        self.pairedEventID = pairedEventID
    }

    public var day: Day { Day(startDateLocal) }
    public var isCycling: Bool { ["Ride", "VirtualRide", "GravelRide", "MountainBikeRide", "EBikeRide", "TrackRide"].contains(type) }
}

// MARK: - Workouts (structured sessions)

public enum SessionKind: String, Codable, Sendable, CaseIterable {
    case rest
    case recovery       // Z1, very easy spin
    case endurance      // Z2
    case tempo          // Z3 / sweet spot
    case threshold      // Z4
    case vo2max         // Z5
    case openerActivation
    case longRide
    case groupRide
    case race
    case strength

    public var isHard: Bool {
        switch self {
        case .threshold, .vo2max, .race, .tempo: return true
        default: return false
        }
    }
}

/// A single block of a structured workout. Intensities are fractions of FTP (0.65 = 65 %).
public struct WorkoutStep: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var duration: TimeInterval
    public var startIntensity: Double
    public var endIntensity: Double     // == startIntensity for a steady block, different for a ramp
    public var cadenceRPM: Int?

    public init(id: UUID = UUID(), name: String, duration: TimeInterval, intensity: Double, cadenceRPM: Int? = nil) {
        self.init(id: id, name: name, duration: duration, startIntensity: intensity, endIntensity: intensity, cadenceRPM: cadenceRPM)
    }

    public init(id: UUID = UUID(), name: String, duration: TimeInterval, startIntensity: Double, endIntensity: Double, cadenceRPM: Int? = nil) {
        self.id = id
        self.name = name
        self.duration = duration
        self.startIntensity = startIntensity
        self.endIntensity = endIntensity
        self.cadenceRPM = cadenceRPM
    }

    public var isRamp: Bool { abs(startIntensity - endIntensity) > 0.001 }

    /// Target fraction of FTP at `elapsed` seconds into the step.
    public func intensity(at elapsed: TimeInterval) -> Double {
        guard isRamp, duration > 0 else { return startIntensity }
        let t = min(max(elapsed / duration, 0), 1)
        return startIntensity + (endIntensity - startIntensity) * t
    }
}

public struct Workout: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var kind: SessionKind
    public var steps: [WorkoutStep]
    /// Hard ceiling for the whole session as a fraction of FTP; the trainer never targets above it.
    public var intensityCeiling: Double?
    public var rationale: String
    public var createdAt: Date

    public init(id: UUID = UUID(), name: String, kind: SessionKind, steps: [WorkoutStep],
                intensityCeiling: Double? = nil, rationale: String = "", createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.kind = kind
        self.steps = steps
        self.intensityCeiling = intensityCeiling
        self.rationale = rationale
        self.createdAt = createdAt
    }

    public var totalDuration: TimeInterval { steps.reduce(0) { $0 + $1.duration } }

    /// Intensity factor approximation: time-weighted mean of step intensity (ramps use their mean).
    public var averageIntensity: Double {
        guard totalDuration > 0 else { return 0 }
        return steps.reduce(0) { $0 + $1.duration * ($1.startIntensity + $1.endIntensity) / 2 } / totalDuration
    }

    /// Estimated training load (TSS-like): hours × IF² × 100.
    public var estimatedLoad: Int {
        let hours = totalDuration / 3600
        let normalized = sqrt(steps.reduce(0) { $0 + $1.duration * pow(($1.startIntensity + $1.endIntensity) / 2, 2) } / max(totalDuration, 1))
        return Int((hours * normalized * normalized * 100).rounded())
    }

    public func targetWatts(ftp: Int, at elapsed: TimeInterval) -> Int? {
        var t = elapsed
        for step in steps {
            if t < step.duration {
                var i = step.intensity(at: t)
                if let ceiling = intensityCeiling { i = min(i, ceiling) }
                return Int((i * Double(ftp)).rounded())
            }
            t -= step.duration
        }
        return nil
    }
}

// MARK: - Plan

public struct PlannedSession: Codable, Equatable, Sendable, Identifiable {
    public enum Status: String, Codable, Sendable {
        case provisional   // intent only; a concrete workout is generated on the day
        case generated     // workout attached, not yet done
        case completed
        case skipped
    }

    public var id: UUID
    public var day: Day
    public var kind: SessionKind
    public var title: String
    public var targetMinutes: Int
    public var targetLoad: Int?
    public var status: Status
    public var workout: Workout?
    public var note: String?
    public var intervalsEventID: Int?
    public var isPriority: Bool

    public init(id: UUID = UUID(), day: Day, kind: SessionKind, title: String, targetMinutes: Int,
                targetLoad: Int? = nil, status: Status = .provisional, workout: Workout? = nil,
                note: String? = nil, intervalsEventID: Int? = nil, isPriority: Bool = false) {
        self.id = id
        self.day = day
        self.kind = kind
        self.title = title
        self.targetMinutes = targetMinutes
        self.targetLoad = targetLoad
        self.status = status
        self.workout = workout
        self.note = note
        self.intervalsEventID = intervalsEventID
        self.isPriority = isPriority
    }
}

public enum GoalKind: String, Codable, Sendable, CaseIterable {
    case climbing, ftp, durability, endurance, strength, event
}

public struct TrainingEvent: Codable, Equatable, Sendable, Identifiable {
    public enum Priority: String, Codable, Sendable { case a, b, c }
    public var id: UUID
    public var name: String
    public var day: Day
    public var distanceKm: Double?
    public var priority: Priority
    public var objective: String   // free text: "llegar fresco", "completar fuerte"…
    /// A race is ridden at the limit; a group ride or gran fondo is a priority day but not a race effort.
    public var isRace: Bool

    public init(id: UUID = UUID(), name: String, day: Day, distanceKm: Double? = nil, priority: Priority = .a, objective: String = "", isRace: Bool = false) {
        self.id = id
        self.name = name
        self.day = day
        self.distanceKm = distanceKm
        self.priority = priority
        self.objective = objective
        self.isRace = isRace
    }

    public var sessionKind: SessionKind { isRace ? .race : .groupRide }
}

public struct Availability: Codable, Equatable, Sendable {
    public var hoursPerWeek: Double
    /// Weekday (1 = Sunday … 7 = Saturday) → max minutes. Missing day = unavailable.
    public var minutesByWeekday: [Int: Int]
    public var longRideWeekday: Int

    public init(hoursPerWeek: Double, minutesByWeekday: [Int: Int], longRideWeekday: Int) {
        self.hoursPerWeek = hoursPerWeek
        self.minutesByWeekday = minutesByWeekday
        self.longRideWeekday = longRideWeekday
    }

    public static let typical = Availability(
        hoursPerWeek: 8,
        minutesByWeekday: [2: 60, 3: 75, 4: 60, 5: 75, 7: 120, 1: 240],
        longRideWeekday: 1
    )

    public var availableWeekdays: [Int] { minutesByWeekday.keys.sorted() }
}

public struct TrainingPhase: Codable, Equatable, Sendable, Identifiable {
    public enum Focus: String, Codable, Sendable { case prepare, base, build, peak, taper, consolidate, recover }
    public var id: UUID
    public var focus: Focus
    public var startWeek: Int    // 1-based
    public var endWeek: Int
    public var summary: String

    public init(id: UUID = UUID(), focus: Focus, startWeek: Int, endWeek: Int, summary: String) {
        self.id = id
        self.focus = focus
        self.startWeek = startWeek
        self.endWeek = endWeek
        self.summary = summary
    }
}

/// A multi-week plan. Weeks carry intent and provisional load; sessions become concrete on the day.
public struct TrainingPlan: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var goal: GoalKind
    public var secondaryGoal: GoalKind?
    public var title: String
    public var startDay: Day
    public var endDay: Day
    public var event: TrainingEvent?
    public var availability: Availability
    public var phases: [TrainingPhase]
    public var sessions: [PlannedSession]
    public var isActive: Bool

    public init(id: UUID = UUID(), goal: GoalKind, secondaryGoal: GoalKind? = nil, title: String, startDay: Day, endDay: Day,
                event: TrainingEvent? = nil, availability: Availability, phases: [TrainingPhase],
                sessions: [PlannedSession], isActive: Bool = false) {
        self.id = id
        self.goal = goal
        self.secondaryGoal = secondaryGoal
        self.title = title
        self.startDay = startDay
        self.endDay = endDay
        self.event = event
        self.availability = availability
        self.phases = phases
        self.sessions = sessions
        self.isActive = isActive
    }

    public var weekCount: Int { max(1, (startDay.days(until: endDay) + 6) / 7) }

    public func weekNumber(of day: Day) -> Int? {
        guard day >= startDay, day <= endDay else { return nil }
        return startDay.days(until: day) / 7 + 1
    }

    public func phase(for day: Day) -> TrainingPhase? {
        guard let w = weekNumber(of: day) else { return nil }
        return phases.first { $0.startWeek <= w && w <= $0.endWeek }
    }

    public func sessions(inWeekOf day: Day) -> [PlannedSession] {
        let start = day.startOfWeek()
        let end = start.adding(days: 6)
        return sessions.filter { $0.day >= start && $0.day <= end }.sorted { $0.day < $1.day }
    }
}

// MARK: - Subjective feedback

public struct SubjectiveFeedback: Codable, Equatable, Sendable {
    public enum Legs: String, Codable, Sendable { case fresh, ok, heavy }
    public var day: Day
    public var rpe: Int?                 // 1…10 after a session
    public var legs: Legs?
    public var sleepQuality: Int?        // 1…5
    public var motivation: Int?          // 1…5
    public var note: String?

    public init(day: Day, rpe: Int? = nil, legs: Legs? = nil, sleepQuality: Int? = nil, motivation: Int? = nil, note: String? = nil) {
        self.day = day
        self.rpe = rpe
        self.legs = legs
        self.sleepQuality = sleepQuality
        self.motivation = motivation
        self.note = note
    }
}
