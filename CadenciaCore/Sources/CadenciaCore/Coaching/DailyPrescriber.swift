import Foundation

/// Turns today's planned intent plus today's readiness into a concrete workout.
///
/// Rules of the house:
/// - Readiness can only soften a session (threshold → tempo → endurance → recovery), never harden it,
///   except that `strong` readiness keeps the hard session exactly as planned.
/// - A ceiling is always set so the trainer never pushes above what today allows.
/// - The day before an A-priority event is an opener or rest, whatever the week said.
public struct DailyPrescriber: Sendable {
    public init() {}

    public struct Input: Sendable {
        public var day: Day
        public var planned: PlannedSession?
        public var readiness: Readiness
        public var ftp: Int
        public var availableMinutes: Int?
        public var upcomingPriorityEvent: TrainingEvent?

        public init(day: Day, planned: PlannedSession?, readiness: Readiness, ftp: Int, availableMinutes: Int? = nil, upcomingPriorityEvent: TrainingEvent? = nil) {
            self.day = day
            self.planned = planned
            self.readiness = readiness
            self.ftp = ftp
            self.availableMinutes = availableMinutes
            self.upcomingPriorityEvent = upcomingPriorityEvent
        }
    }

    public func prescribe(_ input: Input) -> Workout {
        let plannedKind = input.planned?.kind ?? .endurance
        var minutes = input.planned?.targetMinutes ?? 60
        if let cap = input.availableMinutes { minutes = min(minutes, cap) }
        minutes = max(minutes, 20)

        var kind = plannedKind
        var reasons: [String] = []

        if let event = input.upcomingPriorityEvent, event.priority == .a {
            let daysOut = input.day.days(until: event.day)
            if daysOut == 1 {
                kind = .openerActivation
                minutes = min(minutes, 30)
                reasons.append("\(event.name) is tomorrow: short activation, legs stay fresh.")
            } else if daysOut == 2, plannedKind.isHard {
                kind = .endurance
                minutes = min(minutes, 60)
                reasons.append("\(event.name) in two days: no intensity this close.")
            }
        }

        switch input.readiness.level {
        case .rest:
            if kind != .openerActivation {
                kind = .rest
                reasons.append("Recovery signals are well below your range; a day off is the productive choice.")
            }
        case .easy:
            if kind.isHard || kind == .longRide {
                kind = .endurance
                minutes = min(minutes, 75)
                reasons.append("Recovery is below usual, so the planned intensity moves and today stays in zone 2.")
            }
        case .normal:
            if kind == .vo2max {
                kind = .threshold
                reasons.append("A normal day: threshold instead of VO₂max keeps the quality without the extra cost.")
            }
        case .strong:
            if kind.isHard { reasons.append("Recovery is above your range: the hard session goes ahead as planned.") }
        }

        if let planned = input.planned {
            reasons.insert("The week asks for \(Self.name(for: planned.kind).lowercased()) today (\(planned.targetMinutes) min).", at: 0)
        }
        reasons.append(input.readiness.summary)

        let ceiling = Self.ceiling(for: kind, readiness: input.readiness.level)
        let steps = Self.steps(kind: kind, minutes: minutes)
        let name = Self.name(for: kind)
        var workout = Workout(name: name, kind: kind, steps: steps, intensityCeiling: ceiling, rationale: "")
        reasons.append(Self.purpose(for: kind))
        if !steps.isEmpty { reasons.append(Self.numbers(for: workout, ftp: input.ftp)) }
        workout.rationale = reasons.joined(separator: " ")
        return workout
    }

    /// What the session is for, physiologically, so the athlete knows what "done right" feels like.
    static func purpose(for kind: SessionKind) -> String {
        switch kind {
        case .rest: return "Adaptation happens on days like this; the load from the last block is absorbed, not added to."
        case .recovery: return "Very light spinning speeds recovery by moving blood through the legs without adding training load."
        case .endurance: return "Zone 2 builds mitochondrial density and fat oxidation; it should feel conversational the whole way."
        case .tempo: return "Sweet spot (88 % FTP) accumulates time close to threshold at a cost you can repeat tomorrow."
        case .threshold: return "Intervals at 98 % FTP raise the power you can hold for an hour; the last repeat should be hard but controlled."
        case .vo2max: return "Three-minute efforts at 118 % FTP push oxygen uptake; expect to be gasping by the end of each one."
        case .openerActivation: return "Short bursts wake the legs up without fatigue so you arrive at the event sharp."
        case .longRide: return "Long steady riding builds durability: the ability to still produce power after hours in the saddle."
        case .groupRide: return "Ride with the group; the load is whatever the group makes it, and it is logged as it comes."
        case .race: return "Race day. Everything before this was to be fresh now."
        case .strength: return "Off-bike strength protects the joints and adds the force that sprints and climbs draw on."
        }
    }

    /// The numbers: time, power range, ceiling, load. Everything the chart shows, in one line.
    static func numbers(for w: Workout, ftp: Int) -> String {
        let work = w.steps.filter { !$0.isRamp && $0.startIntensity >= 0.6 }
        let main = work.max { $0.duration < $1.duration }
        var parts: [String] = []
        parts.append("\(Int((w.totalDuration / 60).rounded())) min total")
        if let main {
            let watts = Int((main.startIntensity * Double(ftp)).rounded())
            let reps = work.filter { abs($0.startIntensity - main.startIntensity) < 0.01 }.count
            let repText = reps > 1 ? "\(reps) × \(Int((main.duration / 60).rounded())) min" : "\(Int((main.duration / 60).rounded())) min"
            parts.append("\(repText) at \(watts) W (\(Int((main.startIntensity * 100).rounded())) % of \(ftp) W FTP)")
        }
        if let c = w.intensityCeiling, c > 0 {
            parts.append("ceiling \(Int((c * Double(ftp)).rounded())) W")
        }
        parts.append("about \(w.estimatedLoad) TSS, IF \(String(format: "%.2f", w.averageIntensity))")
        return parts.joined(separator: ", ") + "."
    }

    static func ceiling(for kind: SessionKind, readiness: Readiness.Level) -> Double? {
        switch kind {
        case .rest: return 0
        case .recovery: return 0.6
        case .endurance: return readiness <= .easy ? 0.69 : 0.76
        case .openerActivation: return 1.0
        case .tempo: return 0.92
        case .threshold: return 1.05
        case .vo2max: return 1.25
        case .longRide: return 0.85
        case .groupRide, .race, .strength: return nil
        }
    }

    static func name(for kind: SessionKind) -> String {
        switch kind {
        case .rest: return "Rest day"
        case .recovery: return "Recovery spin"
        case .endurance: return "Easy endurance"
        case .tempo: return "Sweet spot"
        case .threshold: return "Threshold"
        case .vo2max: return "VO₂max intervals"
        case .openerActivation: return "Opener"
        case .longRide: return "Long ride"
        case .groupRide: return "Group ride"
        case .race: return "Race"
        case .strength: return "Strength"
        }
    }

    /// Builds the block structure. All durations in minutes are converted to seconds.
    public static func steps(kind: SessionKind, minutes: Int) -> [WorkoutStep] {
        let m = Double(minutes) * 60
        func s(_ name: String, _ mins: Double, _ i: Double, cadence: Int? = nil) -> WorkoutStep {
            WorkoutStep(name: name, duration: mins * 60, intensity: i, cadenceRPM: cadence)
        }
        func ramp(_ name: String, _ mins: Double, _ a: Double, _ b: Double) -> WorkoutStep {
            WorkoutStep(name: name, duration: mins * 60, startIntensity: a, endIntensity: b)
        }
        switch kind {
        case .rest:
            return []
        case .recovery:
            return [ramp("Warm-up", 5, 0.4, 0.5), s("Easy spin", max(Double(minutes) - 10, 5), 0.5, cadence: 90), ramp("Cool-down", 5, 0.5, 0.4)]
        case .endurance:
            return [ramp("Warm-up", 10, 0.45, 0.6), s("Steady endurance", max(Double(minutes) - 15, 10), 0.65, cadence: 88), ramp("Cool-down", 5, 0.55, 0.45)]
        case .longRide:
            return [ramp("Warm-up", 10, 0.45, 0.6), s("Endurance", max(Double(minutes) - 15, 30), 0.68), ramp("Cool-down", 5, 0.55, 0.45)]
        case .openerActivation:
            var steps = [ramp("Warm-up", 8, 0.45, 0.65)]
            for i in 1...3 {
                steps.append(s("Opener \(i)", 1, 1.0, cadence: 95))
                steps.append(s("Easy", 2, 0.5))
            }
            steps.append(ramp("Cool-down", max(Double(minutes) - 17, 3), 0.55, 0.45))
            return steps
        case .tempo:
            let work = max((m - 20 * 60) / 60, 20)
            let blocks = work >= 40 ? 2 : 1
            var steps = [ramp("Warm-up", 12, 0.45, 0.7)]
            for i in 1...blocks {
                steps.append(s("Sweet spot \(i)", (work - Double(blocks - 1) * 5) / Double(blocks), 0.88))
                if i < blocks { steps.append(s("Recovery", 5, 0.5)) }
            }
            steps.append(ramp("Cool-down", 8, 0.55, 0.45))
            return steps
        case .threshold:
            let work = max((m - 25 * 60) / 60, 16)
            let reps = max(Int(work / 12), 2)
            let onMins = min(max((work - Double(reps - 1) * 4) / Double(reps), 6), 10)
            var steps = [ramp("Warm-up", 15, 0.45, 0.75)]
            for i in 1...reps {
                steps.append(s("Threshold \(i)", onMins, 0.98, cadence: 90))
                if i < reps { steps.append(s("Recovery", 4, 0.5)) }
            }
            steps.append(ramp("Cool-down", 10, 0.55, 0.45))
            return steps
        case .vo2max:
            let reps = max(min(Int((m - 25 * 60) / (6 * 60)), 6), 3)
            var steps = [ramp("Warm-up", 15, 0.45, 0.8)]
            for i in 1...reps {
                steps.append(s("VO₂max \(i)", 3, 1.18, cadence: 95))
                if i < reps { steps.append(s("Recovery", 3, 0.45)) }
            }
            steps.append(ramp("Cool-down", 10, 0.55, 0.45))
            return steps
        case .groupRide, .race:
            return [s("Free ride", Double(minutes), 0.7)]
        case .strength:
            return [s("Strength session", Double(minutes), 0.0)]
        }
    }
}
