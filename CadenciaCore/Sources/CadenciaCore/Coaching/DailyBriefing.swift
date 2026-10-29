import Foundation

/// The coach's morning note: what the athlete's body is saying today and why the session is what it is.
/// Written by rules immediately so the screen is never empty, then rewritten by the LLM coach when one is configured.
public struct DailyBriefing: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable {
        case rules   // composed on-device from the readiness signals
        case coach   // written by the LLM coach from the same facts
    }

    public var text: String
    public var source: Source
    /// Fingerprint of the facts the note was written from; a different key means it must be rewritten.
    public var inputsKey: String
    public var generatedAt: Date

    public init(text: String, source: Source, inputsKey: String, generatedAt: Date = Date()) {
        self.text = text
        self.source = source
        self.inputsKey = inputsKey
        self.generatedAt = generatedAt
    }
}

/// Everything the coach may cite in the briefing. Built by the app from `AppState`; nothing here is fetched.
public struct BriefingInput: Sendable {
    public var today: Day
    public var locale: String
    public var athleteName: String?
    public var readiness: Readiness
    public var feedback: SubjectiveFeedback?
    public var workout: Workout
    public var ftp: Int
    public var planned: PlannedSession?
    /// Rides in the seven days before today.
    public var recentActivities: [ActivitySummary]
    public var phase: TrainingPhase?
    public var event: TrainingEvent?

    public init(today: Day, locale: String = "en", athleteName: String? = nil, readiness: Readiness, feedback: SubjectiveFeedback? = nil,
                workout: Workout, ftp: Int, planned: PlannedSession? = nil, recentActivities: [ActivitySummary] = [],
                phase: TrainingPhase? = nil, event: TrainingEvent? = nil) {
        self.today = today
        self.locale = locale
        self.athleteName = athleteName
        self.readiness = readiness
        self.feedback = feedback
        self.workout = workout
        self.ftp = ftp
        self.planned = planned
        self.recentActivities = recentActivities
        self.phase = phase
        self.event = event
    }

    // MARK: Derived facts

    /// Watts of the main block (the longest step that is not the warm-up or cool-down).
    public var mainTargetWatts: Int? {
        let body = workout.steps.dropFirst().dropLast()
        guard let main = (body.isEmpty ? workout.steps[...] : body).max(by: { $0.duration < $1.duration }) else { return nil }
        var i = (main.startIntensity + main.endIntensity) / 2
        if let c = workout.intensityCeiling { i = min(i, c) }
        return Int((i * Double(ftp)).rounded())
    }

    public var ceilingWatts: Int? { workout.intensityCeiling.map { Int(($0 * Double(ftp)).rounded()) } }

    public var recentRides: [ActivitySummary] { recentActivities.filter(\.isCycling) }
    public var recentLoad: Int { recentRides.compactMap(\.trainingLoad).reduce(0, +) }
    public var lastHardRide: ActivitySummary? { recentRides.filter { ($0.intensity ?? 0) >= 85 }.max { $0.startDateLocal < $1.startDateLocal } }

    /// Stable fingerprint of the facts that could change the note. Deliberately a readable string.
    public var cacheKey: String {
        var parts: [String] = [today.iso, locale, "r\(readiness.score)", readiness.level.rawValue]
        for s in readiness.signals {
            parts.append("\(s.name)=\(s.verdict.rawValue):\(s.value.map { String(format: "%.0f", $0) } ?? "-")")
        }
        parts.append("w=\(workout.kind.rawValue):\(Int(workout.totalDuration)):\(workout.estimatedLoad):\(mainTargetWatts ?? 0):\(ceilingWatts ?? 0)")
        parts.append("ftp=\(ftp)")
        parts.append("legs=\(feedback?.legs?.rawValue ?? "-") mot=\(feedback?.motivation.map(String.init) ?? "-")")
        parts.append("rides=\(recentRides.count):\(recentLoad)")
        parts.append("ev=\(event.map { "\($0.name)@\($0.day.iso)" } ?? "-") ph=\(phase?.focus.rawValue ?? "-")")
        return parts.joined(separator: "|")
    }

    /// Plain-text facts for the LLM. One line per fact, no prose, so the model has nothing to misread.
    public func factsSheet() -> String {
        var lines: [String] = []
        lines.append("Date: \(today.iso)")
        if let athleteName, !athleteName.isEmpty { lines.append("Athlete: \(athleteName)") }
        lines.append("Working FTP: \(ftp) W")
        lines.append("Readiness verdict: \(readiness.level.rawValue) (score \(readiness.score)/100)")
        for s in readiness.signals {
            let value = ReadinessEngine.describe(s) ?? "\(ReadinessEngine.label(s.name)): no data today"
            lines.append("Signal \(ReadinessEngine.label(s.name)): \(value); verdict \(s.verdict.rawValue); weight \(Int(s.weight))")
        }
        if !readiness.missingData.isEmpty { lines.append("Missing today: \(readiness.missingData.map(ReadinessEngine.label).joined(separator: ", "))") }
        if let legs = feedback?.legs { lines.append("Athlete says legs feel: \(legs.rawValue)") }
        if let m = feedback?.motivation { lines.append("Athlete motivation: \(m)/5") }
        if let note = feedback?.note, !note.isEmpty { lines.append("Athlete note: \(note)") }

        if workout.kind == .rest || workout.steps.isEmpty {
            lines.append("Today's session: rest day")
        } else {
            var session = "Today's session: \(workout.name), \(Int(workout.totalDuration / 60)) min, about \(workout.estimatedLoad) TSS"
            if let t = mainTargetWatts { session += ", main block \(t) W" }
            if let c = ceilingWatts { session += ", ceiling \(c) W" }
            lines.append(session)
            lines.append("Blocks: " + workout.outline.map { row in
                let w = Int(((row.work.startIntensity + row.work.endIntensity) / 2 * Double(ftp)).rounded())
                let reps = row.repeats > 1 ? "\(row.repeats) × " : ""
                return "\(reps)\(row.title) \(Int(row.work.duration / 60)) min at \(w) W"
            }.joined(separator: "; "))
        }
        if let planned, planned.kind != workout.kind {
            lines.append("The plan asked for: \(planned.title) (\(planned.kind.rawValue), \(planned.targetMinutes) min); it was changed because of readiness")
        } else if let planned {
            lines.append("The plan asked for: \(planned.title) (\(planned.targetMinutes) min); kept as planned")
        }
        lines.append("Session rationale: \(workout.rationale)")

        if recentRides.isEmpty {
            lines.append("Last 7 days: no rides")
        } else {
            lines.append("Last 7 days: \(recentRides.count) rides, \(recentLoad) TSS")
            if let hard = lastHardRide {
                lines.append("Last hard ride: \(hard.name.isEmpty ? hard.type : hard.name), \(today.days(until: hard.day) * -1) days ago, IF \(String(format: "%.2f", (hard.intensity ?? 0) / 100))")
            }
        }
        if let phase { lines.append("Plan phase: \(phase.focus.rawValue) — \(phase.summary)") }
        if let event { lines.append("Next event: \(event.name) on \(event.day.iso), in \(today.days(until: event.day)) days, priority \(event.priority.rawValue.uppercased())") }
        return lines.joined(separator: "\n")
    }
}

/// On-device briefing. Speaks to the athlete in the second person, quotes the numbers that matter against
/// their own range, and ties them to the session. English only; the LLM coach handles other languages.
public enum RuleBriefing {
    public static func compose(_ input: BriefingInput) -> String {
        var sentences: [String] = []
        sentences.append(bodySentence(input))
        if let missing = missingSentence(input) { sentences.append(missing) }
        sentences.append(contentsOf: sessionSentences(input))
        if let context = contextSentence(input) { sentences.append(context) }
        return sentences.joined(separator: " ")
    }

    // MARK: Body

    static func bodySentence(_ input: BriefingInput) -> String {
        let r = input.readiness
        let informed = r.signals.filter { $0.verdict != .missing && $0.name != "motivation" }
        var phrases = informed.compactMap { phrase($0) }
        if let legs = input.feedback?.legs {
            // Replace the engine's generic "legs" phrase with the athlete's own words.
            phrases.removeAll { $0.hasPrefix("your legs") }
            switch legs {
            case .heavy: phrases.append("you told me your legs are heavy, and that counts more than any sensor")
            case .fresh: phrases.append("your legs feel fresh")
            case .ok: break
            }
        }
        if phrases.isEmpty {
            return "I have no recovery data for you this morning, so I am reading today conservatively."
        }
        let list = joined(phrases)
        switch r.level {
        case .strong: return "Everything points up today: \(list)."
        case .normal: return "Your body is in its normal range today: \(list)."
        case .easy: return "Today asks for restraint: \(list)."
        case .rest: return "Your body is asking for a day off: \(list)."
        }
    }

    static func phrase(_ s: Readiness.Signal) -> String? {
        func range(_ r: ClosedRange<Double>?, _ f: (Double) -> String) -> String? {
            r.map { "\(f($0.lowerBound))–\(f($0.upperBound))" }
        }
        let int = { (x: Double) in "\(Int(x.rounded()))" }
        let hours = { (x: Double) in String(format: "%.1f", x / 3600) }
        switch s.name {
        case "hrv":
            guard let v = s.value else { return nil }
            let usual = range(s.baseline, int).map { " against your usual \($0)" } ?? ""
            switch s.verdict {
            case .below: return "HRV is down at \(int(v)) ms\(usual)"
            case .above: return "HRV is up at \(int(v)) ms\(usual)"
            default: return "HRV is \(int(v)) ms, inside your usual \(range(s.baseline, int) ?? "range")"
            }
        case "sleep":
            guard let v = s.value else { return nil }
            let usual = range(s.baseline, hours)
            switch s.verdict {
            case .below: return "you slept only \(hours(v)) h" + (usual.map { ", short of your usual \($0)" } ?? "")
            case .above: return "you slept \(hours(v)) h, more than usual"
            default: return "you slept \(hours(v)) h" + (usual.map { " (usual \($0))" } ?? "")
            }
        case "restingHR":
            guard let v = s.value else { return nil }
            switch s.verdict {
            case .above: return "resting HR is \(int(v)), above your usual \(range(s.baseline, int) ?? "range"), which often means fatigue or something brewing"
            case .below: return "resting HR is low at \(int(v))"
            default: return "resting HR \(int(v)) is normal for you"
            }
        case "form":
            guard let v = s.value else { return nil }
            let tsb = "\(v >= 0 ? "+" : "−")\(Int(abs(v).rounded()))"
            if v < -30 { return "form is deep in the red at \(tsb), fatigue has piled up" }
            if v < -20 { return "form is negative at \(tsb), you are carrying fatigue" }
            if v > 5 { return "you are fresh (form \(tsb))" }
            return "form is neutral at \(tsb), which is where productive training happens"
        case "fatigue":
            guard let v = s.value, let r = s.baseline else { return nil }
            let ctl = Int((r.upperBound / 1.3).rounded())
            if s.weight < 0 { return "fatigue is climbing fast (ATL \(int(v)) against fitness \(ctl))" }
            return "fatigue matches your fitness (ATL \(int(v)) vs CTL \(ctl))"
        case "legs":
            switch s.verdict {
            case .below: return "your legs feel heavy"
            case .above: return "your legs feel fresh"
            default: return nil
            }
        default:
            return nil
        }
    }

    static func missingSentence(_ input: BriefingInput) -> String? {
        let r = input.readiness
        let missing = r.missingData.filter { ["hrv", "sleep", "restingHR"].contains($0) }
        guard !missing.isEmpty else { return nil }
        let informed = r.signals.filter { $0.verdict != .missing }.map { ReadinessEngine.label($0.name) }
        guard !informed.isEmpty else { return nil } // the body sentence already said there is nothing to read
        return "No \(joined(missing.map(ReadinessEngine.label), conjunction: "or")) came in today, so I am leaning on \(joined(informed))."
    }

    // MARK: Session

    static func sessionSentences(_ input: BriefingInput) -> [String] {
        let w = input.workout
        if w.kind == .rest || w.steps.isEmpty {
            return ["So no ride today. " + DailyPrescriber.purpose(for: .rest)]
        }
        var out: [String] = []
        let minutes = Int(w.totalDuration / 60)
        let length = minutes % 60 == 0 ? "\(minutes / 60) h" : (minutes > 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min")
        var line: String
        switch input.readiness.level {
        case .strong: line = "That is why the hard session goes ahead: \(length) \(w.name.lowercased())"
        case .normal: line = "That makes today a normal training day: \(length) \(w.name.lowercased())"
        case .easy: line = "So today stays easy: \(length) \(w.name.lowercased())"
        case .rest: line = "So today is just \(length) \(w.name.lowercased())"
        }
        if let t = input.mainTargetWatts {
            line += " at \(t) W"
            if let c = input.ceilingWatts, c != t { line += ", never above \(c) W" }
        }
        line += "."
        out.append(line)
        if let planned = input.planned, planned.kind != w.kind, planned.kind != .rest {
            out.append("The week asked for \(planned.title.lowercased()); I moved it rather than dropping it.")
        }
        out.append(DailyPrescriber.purpose(for: w.kind))
        return out
    }

    // MARK: Context

    static func contextSentence(_ input: BriefingInput) -> String? {
        var parts: [String] = []
        let rides = input.recentRides
        if !rides.isEmpty {
            var s = "You have ridden \(rides.count) \(rides.count == 1 ? "time" : "times") in the last seven days for \(input.recentLoad) TSS"
            if let hard = input.lastHardRide {
                let ago = -input.today.days(until: hard.day)
                s += ", the last hard one \(ago == 0 ? "today" : ago == 1 ? "yesterday" : "\(ago) days ago")"
            }
            parts.append(s + ".")
        }
        if let event = input.event {
            let days = input.today.days(until: event.day)
            var s = "\(event.name) is \(days == 0 ? "today" : days == 1 ? "tomorrow" : "in \(days) days")"
            if let phase = input.phase { s += "; this is a \(phase.focus.rawValue) week, \(phase.summary.prefix(1).lowercased() + phase.summary.dropFirst())" }
            parts.append(s.hasSuffix(".") ? s : s + ".")
        } else if let phase = input.phase {
            parts.append("This is a \(phase.focus.rawValue) week: \(phase.summary)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    static func joined(_ items: [String], conjunction: String = "and") -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) \(conjunction) \(items[1])"
        default: return items.dropLast().joined(separator: ", ") + ", \(conjunction) " + items.last!
        }
    }
}
