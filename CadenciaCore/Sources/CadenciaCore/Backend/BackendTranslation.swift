import Foundation

/// The backend's ids. Every athlete-scoped id starts with `<athleteId>:`, which is how the backend
/// decides who may read or change it. Each is built from parts that already have the brand's shape.
public enum BackendID {
    /// One athlete's decision for one day: `<athleteId>:YYYY-MM-DD`.
    public static func decision(athlete: CadenciaAPI.AthleteId, day: Day) -> CadenciaAPI.DailyDecisionId {
        CadenciaAPI.DailyDecisionId(rawValue: "\(athlete.rawValue):\(day.iso)")!
    }
    /// One month of the athlete's conversation with the coach: `<athleteId>:YYYY-MM`.
    public static func conversation(athlete: CadenciaAPI.AthleteId, day: Day) -> CadenciaAPI.ConversationId {
        CadenciaAPI.ConversationId(rawValue: "\(athlete.rawValue):" + String(format: "%04d-%02d", day.year, day.month))!
    }
    /// A new plan: `<athleteId>:<uuid>`.
    public static func newPlan(athlete: CadenciaAPI.AthleteId) -> CadenciaAPI.PlanId {
        CadenciaAPI.PlanId(rawValue: "\(athlete.rawValue):\(newKey())")!
    }
    /// A new consultation: `<athleteId>:<uuid>`.
    public static func newConsultation(athlete: CadenciaAPI.AthleteId) -> CadenciaAPI.ConsultationId {
        CadenciaAPI.ConsultationId(rawValue: "\(athlete.rawValue):\(newKey())")!
    }
    /// A new message of the conversation, chosen by its author.
    public static func newMessage() -> CadenciaAPI.MessageId { CadenciaAPI.MessageId(rawValue: newKey())! }

    /// A random key: a lowercase UUID.
    static func newKey() -> String { UUID().uuidString.lowercased() }
}

extension CadenciaAPI.Day {
    /// `Day.iso` is always a `YYYY-MM-DD` calendar day.
    public init(_ day: CadenciaCore.Day) { self.init(rawValue: day.iso)! }
}

extension Day {
    public init?(_ day: CadenciaAPI.Day) { self.init(iso: day.rawValue) }
}

extension CadenciaAPI.Fingerprint {
    /// The lowercase hex of a SHA-256 digest.
    public init<Digest: Sequence>(sha256 digest: Digest) where Digest.Element == UInt8 {
        self.init(rawValue: digest.map { String(format: "%02x", $0) }.joined())!
    }
}

extension CadenciaAPI.Minutes {
    /// Minutes within one day: what Intervals says, held to 0…1440.
    public init(clamping minutes: Int) { self.init(rawValue: min(max(minutes, 0), 1440))! }
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
    /// The AI's workout as the domain takes it. Its names and rationale are trimmed and shortened to fit;
    /// a block outside the domain's ranges throws `CadenciaAPI.InvalidValue`.
    public init(_ workout: Workout) throws {
        try self.init(name: .init(fitting: workout.name), kind: .init(workout.kind),
                      steps: workout.steps.map {
                          try .init(name: .init(fitting: $0.name), durationSeconds: .init($0.duration),
                                    startIntensity: .init($0.startIntensity), endIntensity: .init($0.endIntensity),
                                    cadenceRpm: $0.cadenceRPM.flatMap { $0 > 0 ? $0 : nil }.map { try .init($0) })
                      },
                      intensityCeiling: workout.intensityCeiling.flatMap { $0 > 0 ? $0 : nil }.map { try .init($0) },
                      rationale: .fitting(workout.rationale))
    }
}

extension Workout {
    /// The wire workout, with ids derived from `identity` (where it came from, such as the decision and its
    /// attempt), so the same workout read again is the same workout to the ride engine and the views.
    public init(_ workout: CadenciaAPI.Workout, identity: String) {
        self.init(id: StableID.uuid(identity), name: workout.name.rawValue, kind: SessionKind(workout.kind),
                  steps: workout.steps.enumerated().map { index, step in
                      WorkoutStep(id: StableID.uuid("\(identity)#\(index)"), name: step.name.rawValue,
                                  duration: step.durationSeconds.rawValue, startIntensity: step.startIntensity.rawValue,
                                  endIntensity: step.endIntensity.rawValue, cadenceRPM: step.cadenceRpm?.rawValue)
                  },
                  intensityCeiling: workout.intensityCeiling?.rawValue, rationale: workout.rationale?.rawValue ?? "",
                  createdAt: .distantPast)
    }
}

extension CadenciaAPI.CoachNote {
    public init(_ note: CoachNote) throws {
        try self.init(headline: .init(fitting: note.headline), body: .init(fitting: note.body),
                      session: .init(fitting: note.session), watch: .fitting(note.watch))
    }
}

extension CoachNote {
    public init(_ note: CadenciaAPI.CoachNote) {
        self.init(headline: note.headline.rawValue, body: note.body.rawValue, session: note.session.rawValue,
                  watch: note.watch?.rawValue)
    }
}

extension CadenciaAPI.Readiness {
    public init(_ readiness: Readiness) throws {
        try self.init(level: CadenciaAPI.ReadinessLevel(rawValue: readiness.level.rawValue)!,
                      score: CadenciaAPI.ReadinessScore(rawValue: min(max(readiness.score, 0), 100))!,
                      summary: .init(fitting: readiness.summary))
    }
}

// MARK: - The plan's answers

extension CadenciaAPI.Refusal {
    /// Why Planning refused, for the AI asked again: the rule and its details, such as
    /// `hardensPlan: day="2026-11-10", planned="endurance", proposed="threshold"`.
    public var explanation: String {
        guard let detail = detail?.rawValue else { return reason.rawValue }
        return "\(reason.rawValue): \(detail)"
    }
}

// MARK: - Evidence

/// What a daily decision was made from, as the backend records it: the brief's fingerprint, readiness, and
/// each coming day's conditions as Intervals.icu holds them (availability, time away, hard other training,
/// goal events). Planning checks a proposal against this, never against what the AI says about it.
public enum CoachEvidence {
    public static func snapshot(fingerprint: CadenciaAPI.Fingerprint, readiness: Readiness, availability: [IntervalsAvailabilityDay]?,
                                events: [IntervalsEvent], from start: Day, days: Int = 8) throws -> CadenciaAPI.EvidenceSnapshot {
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
            return .init(day: .init(day), maxMinutes: limit?.max_training_time.map { .init(clamping: $0 / 60) }, unavailable: blocked,
                         hardOtherTraining: hard.contains(day) || hard.contains(day.adding(days: -1)))
        }
        let eventDays = Set(events.filter { ["RACE_A", "RACE_B", "RACE_C"].contains($0.category ?? "") }.compactMap(\.day))
        return try .init(fingerprint: fingerprint, readiness: .init(readiness), days: conditions,
                         eventDays: eventDays.sorted().map { .init($0) })
    }
}

// MARK: - Conversation

extension CadenciaAPI.Intent {
    /// The plan change the coach understood from a message, as day limits: a shorter or unavailable day,
    /// and a day the athlete asked something specific of (no limit of its own; the request becomes that
    /// day's requirement once accepted). Nil when nothing in it changes the plan.
    public init?(_ intent: CoachIntent, planId: CadenciaAPI.PlanId, today: Day) throws {
        guard intent.needsClarification.isEmpty else { return nil }
        var limits: [Day: CadenciaAPI.DayLimit] = [:]
        for c in intent.constraints where c.day >= today {
            limits[c.day] = try .init(day: .init(c.day), maxMinutes: c.maxMinutes.map { try .init($0) }, unavailable: c.unavailable)
        }
        if let request = intent.workoutRequest, request.day >= today, limits[request.day] == nil {
            limits[request.day] = try .init(day: .init(request.day), maxMinutes: request.maxMinutes.map { try .init($0) }, unavailable: false)
        }
        guard !limits.isEmpty else { return nil }
        try self.init(planId: planId, summary: .init(fitting: intent.reply), limits: limits.keys.sorted().compactMap { limits[$0] })
    }
}

// MARK: - Plans

extension CadenciaAPI.PlanDraft {
    /// A plan as the backend creates it from a consultation: the intent, the phases and one session per
    /// planned day. Planning checks it again when it is accepted.
    public init(_ plan: TrainingPlan, athleteId: CadenciaAPI.AthleteId, objective: String, rationale: String) throws {
        let phaseOf = { (day: Day) in plan.phase(for: day)?.summary }
        try self.init(athleteId: athleteId, title: .init(fitting: plan.title), goal: CadenciaAPI.GoalKind(rawValue: plan.goal.rawValue)!,
                      objective: .init(fitting: objective), rationale: .init(fitting: rationale),
                      startDay: .init(plan.startDay), endDay: .init(plan.endDay),
                      phases: plan.phases.map {
                          try .init(focus: CadenciaAPI.PhaseFocus(rawValue: $0.focus.rawValue)!, startWeek: .init($0.startWeek),
                                    endWeek: .init($0.endWeek), summary: .init(fitting: $0.summary))
                      },
                      longRideWeekday: .init(plan.availability.longRideWeekday),
                      event: plan.event.map {
                          try .init(name: .init(fitting: $0.name), day: .init($0.day), distanceKm: $0.distanceKm.map { try .init($0) },
                                    isRace: $0.isRace)
                      },
                      sessions: plan.sessions.filter { $0.status != .skipped }.sorted { $0.day < $1.day }.map {
                          try .init(day: .init($0.day), kind: .init($0.kind), title: .init(fitting: $0.title),
                                    targetMinutes: .init($0.targetMinutes),
                                    purpose: .init(fitting: $0.note ?? phaseOf($0.day) ?? $0.kind.defaultTitle))
                      })
    }

    /// The coach's consultation draft, expanded into its sessions.
    public init(_ draft: PlanConsultation.Draft, athleteId: CadenciaAPI.AthleteId, today: Day) throws {
        let plan = try draft.makePlan(today: today)
        try self.init(plan, athleteId: athleteId, objective: draft.details.objective, rationale: draft.details.rationale)
    }
}

/// What the plan's days and calendar entries need besides the backend's plan: what Intervals.icu holds
/// natively (weekly availability, time away, other training, the goal event's priority) and the event's
/// course, which only this phone has. Written when a plan is accepted, read back from Intervals on sync.
public struct PlanContext: Codable, Equatable, Sendable {
    public var planId: CadenciaAPI.PlanId
    public var availability: Availability?
    public var details: PlanConsultation.Details?
    public var event: TrainingEvent?

    public init(planId: CadenciaAPI.PlanId, availability: Availability? = nil, details: PlanConsultation.Details? = nil,
                event: TrainingEvent? = nil) {
        self.planId = planId; self.availability = availability; self.details = details; self.event = event
    }
}

extension TrainingPlan {
    /// The plan the backend's `CurrentPlan` view shows, as the app's screens and the coach brief read it.
    /// Nil when the athlete has no plan. Sessions are completed later from Intervals (`adoptIntervalsCompletion`).
    public init?(_ view: CadenciaAPI.CurrentPlanState, context: PlanContext?) {
        guard view.status != .none, let planId = view.planId, let startDay = view.startDay, let endDay = view.endDay,
              let start = Day(startDay), let end = Day(endDay) else { return nil }
        let context = context?.planId == planId ? context : nil
        let sessions = view.sessions.compactMap { s -> PlannedSession? in
            guard let day = Day(s.day) else { return nil }
            let kind = SessionKind(s.kind)
            let minutes = s.targetMinutes.rawValue
            let workout = s.workout.map { Workout($0, identity: "\(planId)/\(s.sessionId)/\(s.day)") }
            var session = PlannedSession(id: StableID.uuid("\(planId)/\(s.sessionId)"), day: day, kind: kind, title: s.title.rawValue,
                                         targetMinutes: minutes,
                                         targetLoad: workout?.estimatedLoad ?? PlanBuilder.provisionalLoad(kind: kind, minutes: minutes),
                                         status: PlannedSession.Status(s.status, hasWorkout: workout != nil), workout: workout,
                                         note: s.purpose.rawValue, isPriority: view.event?.day == s.day)
            session.externalID = s.externalId.rawValue
            session.backendID = s.sessionId
            return session
        }
        let minutes = Dictionary(sessions.filter { !$0.isPriority && $0.status != .skipped }.map { ($0.day.weekday(), $0.targetMinutes) },
                                 uniquingKeysWith: max)
        let longRide = view.longRideWeekday?.rawValue ?? minutes.max { $0.value < $1.value }?.key ?? 1
        let derived = Availability(hoursPerWeek: Double(minutes.values.reduce(0, +)) / 60, minutesByWeekday: minutes,
                                   longRideWeekday: longRide)
        let event = view.event.flatMap { e -> TrainingEvent? in
            guard let day = Day(e.day) else { return nil }
            var event = TrainingEvent(id: StableID.uuid("\(planId)/event"), name: e.name.rawValue, day: day,
                                      distanceKm: e.distanceKm?.rawValue, objective: e.objective.rawValue, isRace: e.isRace)
            if let local = context?.event {
                event.priority = local.priority
                event.course = local.course
                event.details = local.details
                event.externalID = local.externalID
            }
            return event
        }
        self.init(id: StableID.uuid(planId.rawValue), goal: view.goal.flatMap { GoalKind(rawValue: $0.rawValue) } ?? .endurance,
                  title: view.title?.rawValue ?? "", startDay: start, endDay: end, event: event,
                  availability: context?.availability ?? derived,
                  phases: view.phases.map {
                      TrainingPhase(id: StableID.uuid("\(planId)/phase/\($0.startWeek)"),
                                    focus: TrainingPhase.Focus(rawValue: $0.focus.rawValue) ?? .base,
                                    startWeek: $0.startWeek.rawValue, endWeek: $0.endWeek.rawValue, summary: $0.summary.rawValue)
                  },
                  sessions: sessions.sorted { $0.day < $1.day }, isActive: view.status == .active)
        backendID = planId
        consultation = context?.details
        requirements = view.requirements.compactMap { r in
            Day(r.day).map { CoachIntent.WorkoutRequest(day: $0, instructions: r.instructions.rawValue, maxMinutes: r.maxMinutes?.rawValue) }
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
    public init(_ report: CyclistProfile.Report) throws {
        let paragraphs = { (texts: [String]) in try texts.compactMap { try CadenciaAPI.Paragraph.fitting($0) } }
        try self.init(riderType: CadenciaAPI.RiderType(rawValue: report.riderType.rawValue)!,
                      confidence: CadenciaAPI.ProfileConfidence(rawValue: report.confidence.rawValue)!,
                      headline: .init(fitting: report.headline), summary: .init(fitting: report.summary),
                      strengths: paragraphs(report.strengths), development: paragraphs(report.development),
                      evidence: paragraphs(report.evidence), caveats: paragraphs(report.caveats),
                      oldest: .init(report.oldest), newest: .init(report.newest), rideCount: .init(report.rideCount))
    }
}

extension CyclistProfile.Report {
    /// The profile the backend recorded. It keeps no generation time; the newest day of the history it read stands in.
    public init?(_ card: CadenciaAPI.RiderProfileCardState) {
        guard let r = card.report, let oldest = Day(r.oldest), let newest = Day(r.newest),
              let type = CyclistProfile.RiderType(rawValue: r.riderType.rawValue),
              let confidence = CyclistProfile.Confidence(rawValue: r.confidence.rawValue) else { return nil }
        self.init(riderType: type, confidence: confidence, headline: r.headline.rawValue, summary: r.summary.rawValue,
                  strengths: r.strengths.map(\.rawValue), development: r.development.map(\.rawValue),
                  evidence: r.evidence.map(\.rawValue), caveats: r.caveats.map(\.rawValue), oldest: oldest, newest: newest,
                  rideCount: r.rideCount.rawValue, model: card.model?.rawValue ?? "", generatedAt: newest.date())
    }
}
