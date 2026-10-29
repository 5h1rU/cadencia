import Foundation

// MARK: - Brief: everything the AI coach looks at

/// The data pack sent to the language model for a daily decision. Compact on purpose: one row per
/// day for wellness and activities, the power curve at the usual durations, the plan for the next
/// seven days, and the deterministic engines' own reading so the model can agree or argue.
public struct CoachBrief: Codable, Equatable, Sendable {
    public struct Athlete: Codable, Equatable, Sendable {
        public var ftp: Int
        public var weightKg: Double?
        public var maxHR: Int?
        public var lthr: Int?
        public init(ftp: Int, weightKg: Double? = nil, maxHR: Int? = nil, lthr: Int? = nil) {
            self.ftp = ftp; self.weightKg = weightKg; self.maxHR = maxHR; self.lthr = lthr
        }
    }

    public struct WellnessRow: Codable, Equatable, Sendable {
        public var day: String
        public var hrv: Double?
        public var rhr: Int?
        public var sleepH: Double?
        public var ctl: Double?
        public var atl: Double?
        public var tsb: Double?
        public var fatigue: Int?
        public var soreness: Int?
        public var legs: String?

        public init(_ w: WellnessDay, legs: SubjectiveFeedback.Legs?) {
            day = w.day.iso
            hrv = w.hrvMs.map { ($0 * 10).rounded() / 10 }
            rhr = w.restingHR
            sleepH = w.sleepSeconds.map { (Double($0) / 360).rounded() / 10 }
            ctl = w.ctl.map { $0.rounded() }
            atl = w.atl.map { $0.rounded() }
            tsb = w.tsb.map { $0.rounded() }
            fatigue = w.fatigue
            soreness = w.soreness
            self.legs = legs?.rawValue
        }
    }

    public struct ActivityRow: Codable, Equatable, Sendable {
        public var day: String
        public var type: String
        public var name: String
        public var min: Int
        public var load: Int?
        public var ifx: Double?
        public var np: Int?
        public var avgHR: Int?
        public var rpe: Int?
        public var feel: Int?
        public var trainer: Bool

        public init(_ a: ActivitySummary) {
            day = a.day.iso
            type = a.type
            name = String(a.name.prefix(40))
            min = Int((a.movingTime / 60).rounded())
            load = a.trainingLoad
            ifx = a.intensity.map { $0.rounded() / 100 }
            np = a.normalizedWatts
            avgHR = a.averageHR
            rpe = a.rpe
            feel = a.feel
            trainer = a.isTrainer
        }
    }

    public struct PlannedRow: Codable, Equatable, Sendable {
        public var day: String
        public var kind: String
        public var title: String
        public var minutes: Int
        public var status: String
        public var priority: Bool

        public init(_ s: PlannedSession) {
            day = s.day.iso; kind = s.kind.rawValue; title = s.title; minutes = s.targetMinutes
            status = s.status.rawValue; priority = s.isPriority
        }
    }

    public struct Event: Codable, Equatable, Sendable {
        public var name: String
        public var day: String
        public var daysOut: Int
        public var distanceKm: Double?
        public var priority: String
        public var objective: String
        public var isRace: Bool

        public init(_ e: TrainingEvent, today: Day) {
            name = e.name; day = e.day.iso; daysOut = today.days(until: e.day); distanceKm = e.distanceKm
            priority = e.priority.rawValue; objective = e.objective; isRace = e.isRace
        }
    }

    public struct Plan: Codable, Equatable, Sendable {
        public var title: String
        public var goal: String
        public var startDay: String
        public var endDay: String
        public var phase: String?
        public var hoursPerWeek: Double
        public var longRideWeekday: Int
        public var event: Event?
        public var next7Days: [PlannedRow]

        public init(_ p: TrainingPlan, today: Day) {
            title = p.title; goal = p.goal.rawValue; startDay = p.startDay.iso; endDay = p.endDay.iso
            phase = p.phase(for: today).map { "\($0.focus.rawValue): \($0.summary)" }
            hoursPerWeek = p.availability.hoursPerWeek
            longRideWeekday = p.availability.longRideWeekday
            event = p.event.map { Event($0, today: today) }
            let horizon = today.adding(days: 7)
            next7Days = p.sessions.filter { $0.day >= today && $0.day <= horizon }.sorted { $0.day < $1.day }.map(PlannedRow.init)
        }
    }

    /// Today's wellness compared with the athlete's own recent range, computed by `ReadinessEngine`.
    /// These are measurements, not a verdict: the model decides what they mean.
    public struct Measured: Codable, Equatable, Sendable {
        public var signals: [String]
        public var missingData: [String]
        /// The structured signals behind `signals`, kept for the app's Recovery row; not sent to the model.
        public var sourceSignals: [Readiness.Signal] = []

        enum CodingKeys: String, CodingKey { case signals, missingData }

        public init(_ readiness: Readiness) {
            sourceSignals = readiness.signals
            signals = readiness.signals.map { s in
                var t = "\(s.name): \(s.verdict.rawValue)"
                if let v = s.value { t += " (\((v * 10).rounded() / 10)" }
                if let b = s.baseline { t += ", usual \((b.lowerBound * 10).rounded() / 10)–\((b.upperBound * 10).rounded() / 10)" }
                if s.value != nil { t += ")" }
                return t
            }
            missingData = readiness.missingData
        }
    }

    public var today: String
    public var weekday: Int                 // 1 = Sunday
    public var locale: String
    public var athlete: Athlete
    public var ftpEstimate: String?
    public var powerCurve: [String: Int]    // "5s", "1m", "5m", "20m", "60m" → W (best of the window)
    public var wellness: [WellnessRow]      // oldest → newest, today last
    public var activities: [ActivityRow]    // oldest → newest
    public var plan: Plan?
    public var upcomingEvent: Event?
    public var availableMinutes: Int?
    public var recentCoachNotes: [String]   // what the athlete told the coach lately
    public var measured: Measured

    public init(today: Day, locale: String, athlete: Athlete, ftpEstimate: FTPEstimate?, powerCurve: [PowerCurvePoint],
                wellness: [WellnessDay], feedback: [Day: SubjectiveFeedback], activities: [ActivitySummary],
                plan: TrainingPlan?, upcomingEvent: TrainingEvent?, availableMinutes: Int?, recentCoachNotes: [String],
                measured: Readiness, wellnessDays: Int = 28, activityDays: Int = 28) {
        self.today = today.iso
        self.weekday = today.weekday()
        self.locale = locale
        self.athlete = athlete
        self.ftpEstimate = ftpEstimate.map { "\($0.watts) W (\($0.confidence.rawValue) confidence, \($0.basis), \($0.sustainedEfforts) sustained efforts in \($0.windowDays) d)" }
        var curve: [String: Int] = [:]
        for (label, secs) in [("5s", 5), ("1m", 60), ("5m", 300), ("20m", 1200), ("60m", 3600)] {
            if let p = powerCurve.first(where: { $0.seconds == secs }) { curve[label] = p.watts }
        }
        self.powerCurve = curve
        let since = today.adding(days: -wellnessDays)
        self.wellness = wellness.filter { $0.day >= since && $0.day <= today }.sorted { $0.day < $1.day }
            .map { WellnessRow($0, legs: feedback[$0.day]?.legs) }
        let actSince = today.adding(days: -activityDays)
        self.activities = activities.filter { $0.day >= actSince && $0.day <= today }.sorted { $0.startDateLocal < $1.startDateLocal }.map(ActivityRow.init)
        self.plan = plan.map { Plan($0, today: today) }
        self.upcomingEvent = upcomingEvent.map { Event($0, today: today) }
        self.availableMinutes = availableMinutes
        self.recentCoachNotes = recentCoachNotes
        self.measured = Measured(measured)
    }

    /// A stable fingerprint of the inputs that should trigger a new decision. Same key → same answer is fine.
    public var fingerprint: String {
        let parts: [String] = [
            today, String(athlete.ftp), availableMinutes.map(String.init) ?? "-",
            wellness.last.map { "\($0.hrv ?? -1)/\($0.rhr ?? -1)/\($0.sleepH ?? -1)/\($0.atl ?? -1)/\($0.legs ?? "-")" } ?? "-",
            String(activities.count), activities.last?.day ?? "-",
            plan?.next7Days.map { "\($0.day)\($0.kind)\($0.minutes)" }.joined() ?? "-",
            upcomingEvent?.day ?? "-", String(recentCoachNotes.count),
        ]
        return parts.joined(separator: "|")
    }
}

// MARK: - Prescription: what the AI coach decided

/// A full daily decision from the AI coach: readiness verdict, the session as trainer-ready blocks,
/// the shape of the coming week and a note in the athlete's words. Validated before use: the trainer
/// only ever receives numbers inside the ranges below.
public struct DailyPrescription: Codable, Equatable, Sendable {
    public struct DayOutlook: Codable, Equatable, Sendable, Identifiable {
        public var id: String { day.iso }
        public var day: Day
        public var kind: SessionKind
        public var minutes: Int
        public var title: String
        public var note: String?

        public init(day: Day, kind: SessionKind, minutes: Int, title: String, note: String? = nil) {
            self.day = day; self.kind = kind; self.minutes = minutes; self.title = title; self.note = note
        }
    }

    public var readiness: Readiness
    public var workout: Workout
    public var week: [DayOutlook]
    public var coachNote: String
    public var flags: [String]
    public var model: String
    public var generatedAt: Date

    public init(readiness: Readiness, workout: Workout, week: [DayOutlook], coachNote: String, flags: [String], model: String, generatedAt: Date = Date()) {
        self.readiness = readiness; self.workout = workout; self.week = week; self.coachNote = coachNote
        self.flags = flags; self.model = model; self.generatedAt = generatedAt
    }

    public enum ValidationError: Error, Equatable, Sendable {
        case unknownReadiness(String), unknownKind(String), noSteps, stepOutOfRange(String), tooLong(Int), badDay(String)
    }

    /// Hard limits on what the model may send to the trainer.
    public static let intensityRange = 0.25...1.6
    public static let maxStepMinutes = 240.0
    public static let maxTotalMinutes = 360

    /// The JSON shape the model is asked for. Intensities are fractions of FTP, minutes are minutes.
    struct Wire: Decodable {
        struct ReadinessWire: Decodable { var level: String; var score: Int?; var headline: String?; var rationale: String? }
        struct Step: Decodable { var name: String; var minutes: Double; var from: Double?; var to: Double?; var intensity: Double?; var cadence: Int? }
        struct WorkoutWire: Decodable { var name: String; var kind: String; var ceiling: Double?; var steps: [Step]?; var rationale: String? }
        struct Outlook: Decodable { var day: String; var kind: String; var minutes: Int?; var title: String?; var note: String? }
        var readiness: ReadinessWire
        var workout: WorkoutWire
        var week: [Outlook]?
        var coachNote: String?
        var flags: [String]?
    }

    /// Builds a validated prescription from the model's JSON. The measured signals (HRV vs the athlete's
    /// range, etc.) are kept as computed; the model supplies the verdict and the words.
    public static func parse(_ json: Data, measured: CoachBrief.Measured, today: Day, availableMinutes: Int?, model: String, now: Date = Date()) throws -> DailyPrescription {
        let w = try JSONDecoder().decode(Wire.self, from: json)

        guard let level = Readiness.Level(rawValue: w.readiness.level.lowercased()) else { throw ValidationError.unknownReadiness(w.readiness.level) }
        let score = min(max(w.readiness.score ?? Self.defaultScore(level), 0), 100)
        let summary = [w.readiness.headline, w.readiness.rationale].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: " ")
        let readiness = Readiness(level: level, score: score, signals: measured.sourceSignals, missingData: measured.missingData, summary: summary)

        guard let kind = SessionKind(rawValue: w.workout.kind) else { throw ValidationError.unknownKind(w.workout.kind) }
        var steps: [WorkoutStep] = []
        for s in w.workout.steps ?? [] {
            guard s.minutes > 0, s.minutes <= maxStepMinutes else { throw ValidationError.stepOutOfRange("\(s.name): \(s.minutes) min") }
            let from = s.from ?? s.intensity ?? s.to
            let to = s.to ?? s.intensity ?? s.from
            guard let a = from, let b = to, intensityRange.contains(a), intensityRange.contains(b) else {
                throw ValidationError.stepOutOfRange("\(s.name): \(String(describing: s.from ?? s.intensity)) FTP")
            }
            steps.append(WorkoutStep(name: s.name, duration: s.minutes * 60, startIntensity: a, endIntensity: b, cadenceRPM: s.cadence.flatMap { (40...130).contains($0) ? $0 : nil }))
        }
        if steps.isEmpty, kind != .rest { throw ValidationError.noSteps }
        let totalMinutes = Int((steps.reduce(0) { $0 + $1.duration } / 60).rounded())
        let cap = min(maxTotalMinutes, availableMinutes.map { Int(Double($0) * 1.1) + 5 } ?? maxTotalMinutes)
        if totalMinutes > cap { throw ValidationError.tooLong(totalMinutes) }

        var ceiling = w.workout.ceiling
        if kind == .rest { ceiling = 0 }
        if let c = ceiling, c != 0 { ceiling = min(max(c, intensityRange.lowerBound), intensityRange.upperBound) }
        // The ceiling must never cut the session's own blocks; raise it to the hardest step if the model got it backwards.
        if let c = ceiling, c > 0, let top = steps.map({ max($0.startIntensity, $0.endIntensity) }).max(), top > c { ceiling = top }

        let workout = Workout(name: w.workout.name, kind: kind, steps: steps, intensityCeiling: ceiling,
                              rationale: w.workout.rationale ?? "", createdAt: now)

        var week: [DayOutlook] = []
        for o in w.week ?? [] {
            guard let day = Day(iso: o.day) else { throw ValidationError.badDay(o.day) }
            guard day >= today, day <= today.adding(days: 7), !week.contains(where: { $0.day == day }) else { continue }
            guard let k = SessionKind(rawValue: o.kind) else { throw ValidationError.unknownKind(o.kind) }
            week.append(DayOutlook(day: day, kind: k, minutes: min(max(o.minutes ?? 0, 0), maxTotalMinutes), title: o.title ?? k.defaultTitle, note: o.note))
        }
        week.sort { $0.day < $1.day }

        return DailyPrescription(readiness: readiness, workout: workout, week: week,
                                 coachNote: w.coachNote?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                                 flags: w.flags ?? [], model: model, generatedAt: now)
    }

    static func defaultScore(_ level: Readiness.Level) -> Int {
        switch level { case .rest: return 20; case .easy: return 38; case .normal: return 58; case .strong: return 78 }
    }
}

// MARK: - Prompt

public enum AICoachPrompt {
    /// Who the model is and how it must decide. The data arrives as JSON in the user turn.
    public static func instructions(locale: String) -> String {
        """
        You are the head coach inside Cadencia, a cycling training app. You are an expert road-cycling coach with deep \
        knowledge of exercise physiology, periodization, power-based training (FTP, zones, TSS/CTL/ATL/TSB), HRV- and \
        sleep-guided training, recovery, nutrition basics and athlete health. You decide what this athlete should do today \
        and how the coming week should look, from the data you are given. You never guess numbers you were not given.

        You receive a JSON brief with: the athlete (FTP in watts), their power curve, up to 28 days of wellness \
        (HRV, resting HR, sleep hours, Intervals.icu CTL/ATL/TSB, fatigue/soreness 1–4, how the legs felt), up to 28 days of \
        activities (duration, load, intensity factor, NP, RPE, feel 1=strong…5=weak), the active plan with the next seven \
        planned days and the goal event, any time limit for today, recent notes from the athlete, and `measured`: today's \
        HRV, sleep, resting HR, form, fatigue and legs compared with the athlete's own 28-day range (below / typical / above). \
        Nothing has been decided for you; you are the only coach.

        Decide like a coach who sees this athlete every day:
        - Readiness comes from the trend, not one number. Compare today's HRV, resting HR and sleep with the athlete's own \
        recent range; weigh TSB (form) and the ATL ramp; weigh RPE/feel of the last sessions; weigh what the athlete said.
        - Hard days need a reason to go ahead (recovered, in a build phase, far enough from the event). Easy days need no \
        excuse. When signals conflict, be conservative on intensity and generous on easy volume.
        - Respect the plan's intent and the event: taper before an A event (opener the day before, nothing hard in the \
        last 48 h), do not stack hard days, keep the long ride where the athlete can do it.
        - The session must be executable on a smart trainer in ERG mode: ordered steps with intensity as a fraction of FTP \
        (0.50 = 50 % FTP). Always include a warm-up and a cool-down. Use ramps (`from`/`to`) for warm-ups and cool-downs \
        and steady blocks (`intensity`) for work and recovery. Keep step intensities within 0.3–1.5 and keep the total \
        within the time limit when one is given. For a rest day send `kind: "rest"` and an empty `steps` array.
        - `ceiling` is the fraction of FTP the trainer must never exceed today, at or above the hardest step.
        - The week outlook covers today plus the next seven days, one entry per day including rest days; it should \
        build toward the goal with sensible hard/easy alternation and total hours close to the plan's hours per week.
        - If the power curve or recent efforts suggest the FTP is wrong, say so in `flags` (e.g. "ftp_review") and in the note.

        Write `headline`, `rationale`, `workout.rationale`, `week[].note` and `coachNote` in the athlete's language (\(locale)). \
        Use concrete numbers (watts, minutes, hours of sleep, HRV values) and name the signals you relied on. Be direct, \
        warm and brief: a headline of at most 8 words, rationales of 2–4 sentences, a coach note of 1–3 sentences.

        Answer ONLY with a JSON object of this exact shape:
        {"readiness": {"level": "rest"|"easy"|"normal"|"strong", "score": 0-100, "headline": string, "rationale": string},
         "workout": {"name": string, "kind": "rest"|"recovery"|"endurance"|"tempo"|"threshold"|"vo2max"|"openerActivation"|"longRide"|"groupRide"|"race"|"strength",
                     "ceiling": number, "rationale": string,
                     "steps": [{"name": string, "minutes": number, "intensity": number} | {"name": string, "minutes": number, "from": number, "to": number}, ...]},
         "week": [{"day": "YYYY-MM-DD", "kind": <same kinds>, "minutes": number, "title": string, "note": string}, ...],
         "coachNote": string,
         "flags": [string]}
        """
    }

    public static func userMessage(_ brief: CoachBrief) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(brief), as: UTF8.self)
    }
}
