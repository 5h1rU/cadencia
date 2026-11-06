import Foundation

/// The backend's ids. Every athlete-scoped id starts with `<athleteId>:`, which is how the backend
/// decides who may read or change it.
public enum BackendID {
    /// One athlete's decision for one day.
    public static func decision(athlete: String, day: Day) -> String { "\(athlete):\(day.iso)" }
    /// One month of the athlete's conversation with the coach.
    public static func conversation(athlete: String, day: Day) -> String {
        "\(athlete):" + String(format: "%04d-%02d", day.year, day.month)
    }
    /// A new consultation or plan id: a key without `:` after the athlete.
    public static func new(athlete: String, prefix: String, now: Date = Date()) -> String {
        let stamp = Int(now.timeIntervalSince1970)
        let random = UUID().uuidString.prefix(8).lowercased()
        return "\(athlete):\(prefix)\(stamp)\(random)"
    }
    /// The athlete an id belongs to.
    public static func owner(of id: String) -> String { String(id.prefix { $0 != ":" }) }
}

/// The backend's timestamps: ISO 8601 in UTC, with milliseconds.
public enum BackendDate {
    public static func parse(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}

/// A UUID that is the same every time for the same text, so a view read twice keeps its identities.
public enum StableID {
    public static func uuid(_ text: String) -> UUID {
        var bytes = Array(SHA256.hash(Array(text.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50 // version 5 layout: name-based
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

// MARK: - Workouts and notes

extension CadenciaAPI.SessionKind {
    public init(_ kind: SessionKind) { self = Self(rawValue: kind.rawValue)! }
}

extension SessionKind {
    public init(_ kind: CadenciaAPI.SessionKind) { self = Self(rawValue: kind.rawValue)! }
}

extension CadenciaAPI.Workout {
    public init(_ workout: Workout) {
        self.init(name: workout.name, kind: .init(workout.kind),
                  steps: workout.steps.map {
                      .init(name: $0.name, durationSeconds: $0.duration, startIntensity: $0.startIntensity,
                            endIntensity: $0.endIntensity, cadenceRpm: $0.cadenceRPM)
                  },
                  intensityCeiling: workout.intensityCeiling.flatMap { $0 > 0 ? $0 : nil },
                  rationale: workout.rationale)
    }
}

extension Workout {
    /// The wire workout, with ids derived from `identity` (where it came from, such as the decision and its
    /// attempt), so the same workout read again is the same workout to the ride engine and the views.
    public init(_ workout: CadenciaAPI.Workout, identity: String) {
        self.init(id: StableID.uuid(identity), name: workout.name, kind: SessionKind(workout.kind),
                  steps: workout.steps.enumerated().map { index, step in
                      WorkoutStep(id: StableID.uuid("\(identity)#\(index)"), name: step.name, duration: step.durationSeconds,
                                  startIntensity: step.startIntensity, endIntensity: step.endIntensity, cadenceRPM: step.cadenceRpm)
                  },
                  intensityCeiling: workout.intensityCeiling, rationale: workout.rationale, createdAt: .distantPast)
    }
}

extension CadenciaAPI.CoachNote {
    public init(_ note: CoachNote) {
        self.init(headline: note.headline, body: note.body, session: note.session, watch: note.watch)
    }
}

extension CoachNote {
    public init(_ note: CadenciaAPI.CoachNote) {
        self.init(headline: note.headline, body: note.body, session: note.session, watch: note.watch)
    }
}

extension CadenciaAPI.Readiness {
    public init(_ readiness: Readiness) {
        self.init(level: CadenciaAPI.ReadinessLevel(rawValue: readiness.level.rawValue)!,
                  score: min(max(readiness.score, 0), 100), summary: readiness.summary)
    }
}

// MARK: - Evidence

/// What a daily decision was made from, as the backend records it: the brief's fingerprint, readiness, and
/// each coming day's conditions as Intervals.icu holds them (availability, time away, hard other training,
/// goal events). Planning checks a proposal against this, never against what the AI says about it.
public enum CoachEvidence {
    public static func snapshot(fingerprint: String, readiness: Readiness, availability: [IntervalsAvailabilityDay]?,
                                events: [IntervalsEvent], from start: Day, days: Int = 8) -> CadenciaAPI.EvidenceSnapshot {
        let range = (0..<days).map { start.adding(days: $0) }
        let away = events.filter { ["HOLIDAY", "SICK", "INJURED"].contains($0.category ?? "") }
        let hard = events.filter { $0.category == "WORKOUT" && ($0.tags ?? []).contains("intensity-hard") }.compactMap(\.day)
        let conditions = range.map { day -> CadenciaAPI.DayConditions in
            let iso = IntervalsAvailability.isoDay(fromWeekday: day.weekday())
            let limit = availability?.first { $0.day_of_week == iso }
            let blocked = limit?.training_availability == .unavailable || away.contains { event in
                guard let first = event.day else { return false }
                return day >= first && day <= (event.endDay ?? first)
            }
            return .init(day: day.iso, maxMinutes: limit?.max_training_time.map { $0 / 60 }, unavailable: blocked,
                         hardOtherTraining: hard.contains(day) || hard.contains(day.adding(days: -1)))
        }
        let eventDays = Set(events.filter { ["RACE_A", "RACE_B", "RACE_C"].contains($0.category ?? "") }.compactMap(\.day))
        return .init(fingerprint: fingerprint, readiness: .init(readiness), days: conditions,
                     eventDays: eventDays.sorted().map(\.iso))
    }
}

// MARK: - Conversation

extension CadenciaAPI.Intent {
    /// The plan change the coach understood from a message, as day limits: a shorter or unavailable day,
    /// and a day the athlete asked something specific of (no limit of its own; the request becomes that
    /// day's requirement once accepted). Nil when nothing in it changes the plan.
    public init?(_ intent: CoachIntent, planId: String, today: Day) {
        guard intent.needsClarification.isEmpty else { return nil }
        var limits: [Day: CadenciaAPI.DayLimit] = [:]
        for c in intent.constraints where c.day >= today {
            limits[c.day] = .init(day: c.day.iso, maxMinutes: c.maxMinutes, unavailable: c.unavailable)
        }
        if let request = intent.workoutRequest, request.day >= today, limits[request.day] == nil {
            limits[request.day] = .init(day: request.day.iso, maxMinutes: request.maxMinutes, unavailable: false)
        }
        guard !limits.isEmpty else { return nil }
        self.init(planId: planId, summary: intent.reply, limits: limits.keys.sorted().compactMap { limits[$0] })
    }
}

// MARK: - Plans

extension CadenciaAPI.PlanDraft {
    /// A plan as the backend creates it from a consultation: the intent, the phases and one session per
    /// planned day. Planning checks it again when it is accepted.
    public init(_ plan: TrainingPlan, athleteId: String, objective: String, rationale: String) {
        let phaseOf = { (day: Day) in plan.phase(for: day)?.summary }
        self.init(athleteId: athleteId, title: plan.title, goal: CadenciaAPI.GoalKind(rawValue: plan.goal.rawValue)!,
                  objective: objective, rationale: rationale, startDay: plan.startDay.iso, endDay: plan.endDay.iso,
                  phases: plan.phases.map {
                      .init(focus: CadenciaAPI.PhaseFocus(rawValue: $0.focus.rawValue)!, startWeek: $0.startWeek,
                            endWeek: $0.endWeek, summary: $0.summary)
                  },
                  longRideWeekday: plan.availability.longRideWeekday,
                  event: plan.event.map { .init(name: $0.name, day: $0.day.iso, distanceKm: $0.distanceKm, isRace: $0.isRace) },
                  sessions: plan.sessions.filter { $0.status != .skipped }.sorted { $0.day < $1.day }.map {
                      .init(day: $0.day.iso, kind: .init($0.kind), title: $0.title, targetMinutes: $0.targetMinutes,
                            purpose: $0.note ?? phaseOf($0.day) ?? $0.kind.defaultTitle)
                  })
    }

    /// The coach's consultation draft, expanded into its sessions.
    public init(_ draft: PlanConsultation.Draft, athleteId: String, today: Day) throws {
        let plan = try draft.makePlan(today: today)
        self.init(plan, athleteId: athleteId, objective: draft.details.objective, rationale: draft.details.rationale)
    }
}

/// What the plan's days and calendar entries need besides the backend's plan: what Intervals.icu holds
/// natively (weekly availability, time away, other training, the goal event's priority) and the event's
/// course, which only this phone has. Written when a plan is accepted, read back from Intervals on sync.
public struct PlanContext: Codable, Equatable, Sendable {
    public var planId: String
    public var availability: Availability?
    public var details: PlanConsultation.Details?
    public var event: TrainingEvent?

    public init(planId: String, availability: Availability? = nil, details: PlanConsultation.Details? = nil, event: TrainingEvent? = nil) {
        self.planId = planId; self.availability = availability; self.details = details; self.event = event
    }
}

extension TrainingPlan {
    /// The plan the backend's `CurrentPlan` view shows, as the app's screens and the coach brief read it.
    /// Nil when the athlete has no plan. Sessions are completed later from Intervals (`adoptIntervalsCompletion`).
    public init?(_ view: CadenciaAPI.CurrentPlanState, context: PlanContext?) {
        guard view.status != .none, let planId = view.planId, let startIso = view.startDay, let endIso = view.endDay,
              let start = Day(iso: startIso), let end = Day(iso: endIso) else { return nil }
        let context = context?.planId == planId ? context : nil
        let sessions = view.sessions.compactMap { s -> PlannedSession? in
            guard let day = Day(iso: s.day) else { return nil }
            let kind = SessionKind(s.kind)
            let workout = s.workout.map { Workout($0, identity: "\(planId)/\(s.sessionId)/\(s.day)") }
            var session = PlannedSession(id: StableID.uuid("\(planId)/\(s.sessionId)"), day: day, kind: kind, title: s.title,
                                         targetMinutes: s.targetMinutes,
                                         targetLoad: workout?.estimatedLoad ?? PlanBuilder.provisionalLoad(kind: kind, minutes: s.targetMinutes),
                                         status: PlannedSession.Status(s.status, hasWorkout: workout != nil), workout: workout,
                                         note: s.purpose, isPriority: view.event?.day == s.day)
            session.externalID = s.externalId
            session.backendID = s.sessionId
            return session
        }
        let minutes = Dictionary(sessions.filter { !$0.isPriority && $0.status != .skipped }.map { ($0.day.weekday(), $0.targetMinutes) },
                                 uniquingKeysWith: max)
        let longRide = view.longRideWeekday ?? minutes.max { $0.value < $1.value }?.key ?? 1
        let derived = Availability(hoursPerWeek: Double(minutes.values.reduce(0, +)) / 60, minutesByWeekday: minutes,
                                   longRideWeekday: longRide)
        let event = view.event.flatMap { e -> TrainingEvent? in
            guard let day = Day(iso: e.day) else { return nil }
            var event = TrainingEvent(id: StableID.uuid("\(planId)/event"), name: e.name, day: day, distanceKm: e.distanceKm,
                                      objective: e.objective, isRace: e.isRace)
            if let local = context?.event {
                event.priority = local.priority
                event.course = local.course
                event.details = local.details
                event.externalID = local.externalID
            }
            return event
        }
        self.init(id: StableID.uuid(planId), goal: view.goal.flatMap { GoalKind(rawValue: $0.rawValue) } ?? .endurance,
                  title: view.title, startDay: start, endDay: end, event: event,
                  availability: context?.availability ?? derived,
                  phases: view.phases.map {
                      TrainingPhase(id: StableID.uuid("\(planId)/phase/\($0.startWeek)"),
                                    focus: TrainingPhase.Focus(rawValue: $0.focus.rawValue) ?? .base,
                                    startWeek: $0.startWeek, endWeek: $0.endWeek, summary: $0.summary)
                  },
                  sessions: sessions.sorted { $0.day < $1.day }, isActive: view.status == .active)
        backendID = planId
        consultation = context?.details
        requirements = view.requirements.compactMap { r in
            Day(iso: r.day).map { CoachIntent.WorkoutRequest(day: $0, instructions: r.instructions, maxMinutes: r.maxMinutes) }
        }
    }
}

extension PlannedSession.Status {
    /// A provisional session is an intent; one with a workout the plan accepted is ready to ride. A session
    /// removed from Intervals is not ridden; one changed there is still planned.
    public init(_ status: CadenciaAPI.SessionStatus, hasWorkout: Bool) {
        switch status {
        case .skipped, .removedInIntervals: self = .skipped
        case .provisional, .concrete, .published, .changedInIntervals: self = hasWorkout ? .generated : .provisional
        }
    }
}

// MARK: - Rider profile

extension CadenciaAPI.RiderReport {
    public init(_ report: CyclistProfile.Report) {
        self.init(riderType: CadenciaAPI.RiderType(rawValue: report.riderType.rawValue)!,
                  confidence: CadenciaAPI.ProfileConfidence(rawValue: report.confidence.rawValue)!,
                  headline: report.headline, summary: report.summary, strengths: report.strengths,
                  development: report.development, evidence: report.evidence, caveats: report.caveats,
                  oldest: report.oldest.iso, newest: report.newest.iso, rideCount: report.rideCount)
    }
}

extension CyclistProfile.Report {
    /// The profile the backend recorded. It keeps no generation time; the newest day of the history it read stands in.
    public init?(_ card: CadenciaAPI.RiderProfileCardState) {
        guard let r = card.report, let oldest = Day(iso: r.oldest), let newest = Day(iso: r.newest),
              let type = CyclistProfile.RiderType(rawValue: r.riderType.rawValue),
              let confidence = CyclistProfile.Confidence(rawValue: r.confidence.rawValue) else { return nil }
        self.init(riderType: type, confidence: confidence, headline: r.headline, summary: r.summary, strengths: r.strengths,
                  development: r.development, evidence: r.evidence, caveats: r.caveats, oldest: oldest, newest: newest,
                  rideCount: r.rideCount, model: card.model ?? "", generatedAt: newest.date())
    }
}
