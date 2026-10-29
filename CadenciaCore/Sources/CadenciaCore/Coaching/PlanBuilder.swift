import Foundation

/// Builds a multi-week plan skeleton: phases plus one provisional session per available day.
/// Future sessions are intentions with a provisional load; the concrete workout is generated on the day.
public struct PlanBuilder: Sendable {
    public init() {}

    public struct Request: Sendable {
        public var goal: GoalKind
        public var secondaryGoal: GoalKind?
        public var startDay: Day
        public var endDay: Day
        public var event: TrainingEvent?
        public var availability: Availability
        public var currentCTL: Double?

        public init(goal: GoalKind, secondaryGoal: GoalKind? = nil, startDay: Day, endDay: Day, event: TrainingEvent? = nil, availability: Availability, currentCTL: Double? = nil) {
            self.goal = goal
            self.secondaryGoal = secondaryGoal
            self.startDay = startDay
            self.endDay = endDay
            self.event = event
            self.availability = availability
            self.currentCTL = currentCTL
        }
    }

    public func build(_ r: Request) -> TrainingPlan {
        let weeks = max(1, (r.startDay.days(until: r.endDay) + 6) / 7)
        let phases = Self.phases(weeks: weeks, hasEvent: r.event != nil, goal: r.goal)
        var sessions: [PlannedSession] = []

        for week in 1...weeks {
            let phase = phases.first { $0.startWeek <= week && week <= $0.endWeek }!
            let weekStart = r.startDay.adding(days: (week - 1) * 7).startOfWeek()
            // Recovery week every 4th week (3:1), and the last week before an event is a taper.
            let isRecoveryWeek = phase.focus == .recover || (week % 4 == 0 && phase.focus != .taper)
            let template = Self.weekTemplate(goal: r.goal, phase: phase.focus, recovery: isRecoveryWeek)
            var hardSlots = template.hardSessions

            for offset in 0..<7 {
                let day = weekStart.adding(days: offset)
                guard day >= r.startDay, day <= r.endDay else { continue }
                let weekday = day.weekday()
                guard let minutes = r.availability.minutesByWeekday[weekday] else { continue }

                if let event = r.event, event.day == day {
                    sessions.append(PlannedSession(day: day, kind: event.sessionKind, title: event.name,
                                                   targetMinutes: minutes, status: .provisional, isPriority: event.priority == .a))
                    continue
                }
                if let event = r.event, day.days(until: event.day) == 1 {
                    sessions.append(PlannedSession(day: day, kind: .openerActivation, title: "Opener", targetMinutes: min(minutes, 30)))
                    continue
                }

                let kind: SessionKind
                if weekday == r.availability.longRideWeekday {
                    kind = .longRide
                } else if hardSlots > 0, Self.isGoodHardDay(weekday: weekday, availableDays: r.availability.availableWeekdays, longRide: r.availability.longRideWeekday) {
                    kind = template.hardKind
                    hardSlots -= 1
                } else {
                    kind = isRecoveryWeek ? .recovery : .endurance
                }
                let targetMinutes = kind == .longRide ? minutes : min(minutes, kind.isHard ? 75 : 90)
                let targetLoad = Self.provisionalLoad(kind: kind, minutes: targetMinutes)
                sessions.append(PlannedSession(day: day, kind: kind, title: kind.defaultTitle,
                                               targetMinutes: targetMinutes, targetLoad: targetLoad))
            }
        }

        let title: String
        if let event = r.event {
            title = "\(event.name) · \(weeks) weeks"
        } else {
            title = "\(Self.goalTitle(r.goal)) · \(weeks)-week block"
        }
        return TrainingPlan(goal: r.goal, secondaryGoal: r.secondaryGoal, title: title, startDay: r.startDay, endDay: r.endDay,
                            event: r.event, availability: r.availability, phases: phases, sessions: sessions)
    }

    public static func goalTitle(_ goal: GoalKind) -> String {
        switch goal {
        case .climbing: return "Climb better"
        case .ftp: return "Raise FTP"
        case .durability: return "Durability"
        case .endurance: return "Endurance"
        case .strength: return "Strength"
        case .event: return "Event"
        }
    }

    struct WeekTemplate {
        var hardSessions: Int
        var hardKind: SessionKind
    }

    static func weekTemplate(goal: GoalKind, phase: TrainingPhase.Focus, recovery: Bool) -> WeekTemplate {
        if recovery { return WeekTemplate(hardSessions: 0, hardKind: .endurance) }
        switch phase {
        case .prepare, .base: return WeekTemplate(hardSessions: 1, hardKind: .tempo)
        case .build: return WeekTemplate(hardSessions: 2, hardKind: goal == .ftp ? .threshold : (goal == .climbing ? .threshold : .tempo))
        case .peak: return WeekTemplate(hardSessions: 2, hardKind: goal == .endurance || goal == .durability ? .tempo : .vo2max)
        case .consolidate: return WeekTemplate(hardSessions: 1, hardKind: .threshold)
        case .taper: return WeekTemplate(hardSessions: 1, hardKind: .openerActivation)
        case .recover: return WeekTemplate(hardSessions: 0, hardKind: .endurance)
        }
    }

    /// Hard days keep at least one easy day between them and avoid the day before the long ride.
    static func isGoodHardDay(weekday: Int, availableDays: [Int], longRide: Int) -> Bool {
        let dayBeforeLong = longRide == 1 ? 7 : longRide - 1
        if weekday == dayBeforeLong { return false }
        // Prefer Tuesday (3) and Thursday (5) / Saturday (7).
        return [3, 5, 7].contains(weekday)
    }

    static func provisionalLoad(kind: SessionKind, minutes: Int) -> Int {
        let intensity: Double
        switch kind {
        case .rest: return 0
        case .recovery: intensity = 0.5
        case .endurance, .longRide: intensity = 0.67
        case .tempo: intensity = 0.82
        case .threshold: intensity = 0.88
        case .vo2max: intensity = 0.92
        case .openerActivation: intensity = 0.6
        case .groupRide, .race: intensity = 0.8
        case .strength: return 20
        }
        return Int((Double(minutes) / 60 * intensity * intensity * 100).rounded())
    }

    static func phases(weeks: Int, hasEvent: Bool, goal: GoalKind) -> [TrainingPhase] {
        if weeks <= 2 {
            return [TrainingPhase(focus: .prepare, startWeek: 1, endWeek: weeks, summary: "Consistency and a reference of your current level")]
        }
        if hasEvent {
            // Base → Build → Peak → Taper, proportional, with a 1-week taper.
            let taper = 1
            let remaining = weeks - taper
            let base = max(1, Int(Double(remaining) * 0.45))
            let build = max(1, Int(Double(remaining) * 0.35))
            let peak = max(0, remaining - base - build)
            var out = [TrainingPhase(focus: .base, startWeek: 1, endWeek: base, summary: "Aerobic volume and consistent weeks")]
            out.append(TrainingPhase(focus: .build, startWeek: base + 1, endWeek: base + build, summary: "Progressive sustained efforts toward the event demand"))
            if peak > 0 {
                out.append(TrainingPhase(focus: .peak, startWeek: base + build + 1, endWeek: base + build + peak, summary: "Event-specific intensity, volume held"))
            }
            out.append(TrainingPhase(focus: .taper, startWeek: weeks, endWeek: weeks, summary: "Freshen up, keep a little intensity"))
            return out
        }
        // Capability block: prepare → develop → absorb → consolidate.
        let prepare = max(1, weeks / 4)
        let develop = max(1, weeks * 3 / 8)
        let absorb = 1
        let consolidate = max(1, weeks - prepare - develop - absorb)
        return [
            TrainingPhase(focus: .prepare, startWeek: 1, endWeek: prepare, summary: "Consistency and a reference of your current level"),
            TrainingPhase(focus: .build, startWeek: prepare + 1, endWeek: prepare + develop, summary: "Progression of the \(goalTitle(goal).lowercased()) work"),
            TrainingPhase(focus: .recover, startWeek: prepare + develop + 1, endWeek: prepare + develop + absorb, summary: "Absorb: load adjusted to recovery"),
            TrainingPhase(focus: .consolidate, startWeek: prepare + develop + absorb + 1, endWeek: prepare + develop + absorb + consolidate, summary: "Repeat comparable efforts and review the goal"),
        ]
    }
}

/// What the coach understood from a voice note or message. All fields optional: the UI shows what
/// was understood and asks for the rest.
public struct CoachIntent: Codable, Equatable, Sendable {
    public struct DayConstraint: Codable, Equatable, Sendable, Identifiable {
        public var id: Day { day }
        public var day: Day
        public var maxMinutes: Int?
        public var unavailable: Bool
        public init(day: Day, maxMinutes: Int? = nil, unavailable: Bool = false) {
            self.day = day
            self.maxMinutes = maxMinutes
            self.unavailable = unavailable
        }
    }

    public var event: TrainingEvent?
    public var constraints: [DayConstraint]
    public var feeling: SubjectiveFeedback.Legs?
    public var goal: GoalKind?
    public var reply: String
    public var needsClarification: [String]

    public init(event: TrainingEvent? = nil, constraints: [DayConstraint] = [], feeling: SubjectiveFeedback.Legs? = nil,
                goal: GoalKind? = nil, reply: String = "", needsClarification: [String] = []) {
        self.event = event
        self.constraints = constraints
        self.feeling = feeling
        self.goal = goal
        self.reply = reply
        self.needsClarification = needsClarification
    }

    public var isEmpty: Bool { event == nil && constraints.isEmpty && feeling == nil && goal == nil }
}

/// Applies an understood intent to the current week of a plan: pins the event, shortens constrained
/// days and moves intensity away from the days right before an A event. Returns the changed sessions.
public struct WeekReviser: Sendable {
    public init() {}

    public struct Revision: Equatable, Sendable {
        public var plan: TrainingPlan
        public var changed: [PlannedSession]
        public var notes: [String]
    }

    public func apply(_ intent: CoachIntent, to plan: TrainingPlan, today: Day) -> Revision {
        var plan = plan
        var changed: [PlannedSession] = []
        var notes: [String] = []

        if let event = intent.event {
            if plan.event == nil || plan.event?.day == event.day {
                plan.event = plan.event ?? event
            }
            if let idx = plan.sessions.firstIndex(where: { $0.day == event.day }) {
                plan.sessions[idx].kind = event.sessionKind
                plan.sessions[idx].title = event.name
                plan.sessions[idx].isPriority = event.priority == .a
                plan.sessions[idx].note = event.objective.isEmpty ? nil : event.objective
                changed.append(plan.sessions[idx])
            } else {
                let s = PlannedSession(day: event.day, kind: event.sessionKind, title: event.name,
                                       targetMinutes: Int(((event.distanceKm ?? 100) / 28 * 60).rounded()), isPriority: event.priority == .a)
                plan.sessions.append(s)
                changed.append(s)
            }
            notes.append("\(event.name) on \(event.day.iso) is the priority.")

            // Soften the two days before an A event, but only sessions that are still provisional.
            if event.priority == .a {
                for back in 1...2 {
                    let d = event.day.adding(days: -back)
                    guard d >= today, let idx = plan.sessions.firstIndex(where: { $0.day == d && $0.status == .provisional }) else { continue }
                    let target: SessionKind = back == 1 ? .openerActivation : .endurance
                    if plan.sessions[idx].kind != target {
                        plan.sessions[idx].kind = target
                        plan.sessions[idx].title = target.defaultTitle
                        plan.sessions[idx].targetMinutes = min(plan.sessions[idx].targetMinutes, back == 1 ? 30 : 60)
                        changed.append(plan.sessions[idx])
                    }
                }
                notes.append("The demanding session will not move automatically into the days before the event.")
            }
        }

        for c in intent.constraints {
            guard c.day >= today else { continue }
            if let idx = plan.sessions.firstIndex(where: { $0.day == c.day }) {
                if c.unavailable {
                    plan.sessions[idx].status = .skipped
                    plan.sessions[idx].note = "Unavailable"
                } else if let max = c.maxMinutes, plan.sessions[idx].targetMinutes > max {
                    plan.sessions[idx].targetMinutes = max
                    if plan.sessions[idx].kind.isHard, max < 45 {
                        plan.sessions[idx].kind = .endurance
                        plan.sessions[idx].title = SessionKind.endurance.defaultTitle
                    }
                }
                changed.append(plan.sessions[idx])
            } else if !c.unavailable, let max = c.maxMinutes {
                let s = PlannedSession(day: c.day, kind: .endurance, title: SessionKind.endurance.defaultTitle, targetMinutes: max)
                plan.sessions.append(s)
                changed.append(s)
            }
        }

        plan.sessions.sort { $0.day < $1.day }
        return Revision(plan: plan, changed: changed, notes: notes)
    }
}
