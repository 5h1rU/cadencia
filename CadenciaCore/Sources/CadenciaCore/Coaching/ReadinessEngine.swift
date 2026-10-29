import Foundation

/// How ready the athlete is to absorb intensity today, with the evidence behind it.
public struct Readiness: Codable, Equatable, Sendable {
    public enum Level: String, Codable, Sendable, Comparable {
        case rest, easy, normal, strong

        private var rank: Int {
            switch self {
            case .rest: return 0
            case .easy: return 1
            case .normal: return 2
            case .strong: return 3
            }
        }
        public static func < (lhs: Level, rhs: Level) -> Bool { lhs.rank < rhs.rank }
    }

    public struct Signal: Codable, Equatable, Sendable, Identifiable {
        public enum Verdict: String, Codable, Sendable { case below, typical, above, missing }
        public var id: String { name }
        public var name: String        // "hrv", "sleep", "restingHR", "form", "fatigue", "legs"
        public var verdict: Verdict
        public var value: Double?
        public var baseline: ClosedRange<Double>?
        public var weight: Double      // contribution to the score, negative when it argues for rest

        public init(name: String, verdict: Verdict, value: Double? = nil, baseline: ClosedRange<Double>? = nil, weight: Double) {
            self.name = name
            self.verdict = verdict
            self.value = value
            self.baseline = baseline
            self.weight = weight
        }
    }

    public var level: Level
    /// 0…100. ≥ 70 strong, 45…69 normal, 25…44 easy, < 25 rest.
    public var score: Int
    public var signals: [Signal]
    public var missingData: [String]
    public var summary: String

    public init(level: Level, score: Int, signals: [Signal], missingData: [String], summary: String) {
        self.level = level
        self.score = score
        self.signals = signals
        self.missingData = missingData
        self.summary = summary
    }

    public var isSufficientlyInformed: Bool { signals.filter { $0.verdict != .missing }.count >= 2 }
}

/// Combines HRV, sleep, resting HR, Intervals form (TSB), fatigue (ATL ramp) and the athlete's own
/// words into a single readiness verdict. No single number decides on its own.
public struct ReadinessEngine: Sendable {
    public var baselineDays: Int

    public init(baselineDays: Int = 28) {
        self.baselineDays = baselineDays
    }

    public func evaluate(today: WellnessDay, history: [WellnessDay], feedback: SubjectiveFeedback? = nil) -> Readiness {
        let baseline = history.filter { $0.day < today.day }.sorted { $0.day > $1.day }.prefix(baselineDays)
        var signals: [Readiness.Signal] = []
        var missing: [String] = []
        var score = 55.0

        // HRV: compare against the personal typical range (mean ± 1 SD, min 7 samples).
        let hrvValues = baseline.compactMap(\.hrvMs)
        if let hrv = today.hrvMs, let range = typicalRange(hrvValues) {
            let verdict: Readiness.Signal.Verdict = hrv < range.lowerBound ? .below : (hrv > range.upperBound ? .above : .typical)
            let w: Double = verdict == .below ? -14 : (verdict == .above ? 8 : 2)
            score += w
            signals.append(.init(name: "hrv", verdict: verdict, value: hrv, baseline: range, weight: w))
        } else {
            missing.append("hrv")
            signals.append(.init(name: "hrv", verdict: .missing, value: today.hrvMs, weight: 0))
        }

        // Sleep: below 85 % of usual duration argues for less intensity.
        let sleepValues = baseline.compactMap { $0.sleepSeconds.map(Double.init) }
        if let sleep = today.sleepSeconds.map(Double.init), let range = typicalRange(sleepValues) {
            let usual = (range.lowerBound + range.upperBound) / 2
            let verdict: Readiness.Signal.Verdict = sleep < usual * 0.85 ? .below : (sleep > range.upperBound ? .above : .typical)
            let w: Double = verdict == .below ? -8 : (verdict == .above ? 3 : 0)
            score += w
            signals.append(.init(name: "sleep", verdict: verdict, value: sleep, baseline: range, weight: w))
        } else {
            missing.append("sleep")
            signals.append(.init(name: "sleep", verdict: .missing, value: today.sleepSeconds.map(Double.init), weight: 0))
        }

        // Resting HR: elevated above the typical range is a fatigue/illness marker.
        let rhrValues = baseline.compactMap { $0.restingHR.map(Double.init) }
        if let rhr = today.restingHR.map(Double.init), let range = typicalRange(rhrValues) {
            let verdict: Readiness.Signal.Verdict = rhr > range.upperBound ? .above : (rhr < range.lowerBound ? .below : .typical)
            let w: Double = verdict == .above ? -6 : (verdict == .below ? 2 : 0)
            score += w
            signals.append(.init(name: "restingHR", verdict: verdict, value: rhr, baseline: range, weight: w))
        } else {
            missing.append("restingHR")
            signals.append(.init(name: "restingHR", verdict: .missing, value: today.restingHR.map(Double.init), weight: 0))
        }

        // Form (TSB): deeply negative means accumulated fatigue; slightly negative is productive training.
        if let tsb = today.tsb {
            let verdict: Readiness.Signal.Verdict = tsb < -20 ? .below : (tsb > 5 ? .above : .typical)
            let w: Double = tsb < -30 ? -12 : (tsb < -20 ? -6 : (tsb > 5 ? 5 : 0))
            score += w
            signals.append(.init(name: "form", verdict: verdict, value: tsb, baseline: -20...5, weight: w))
        } else {
            missing.append("form")
            signals.append(.init(name: "form", verdict: .missing, weight: 0))
        }

        // Fatigue ramp: ATL rising fast relative to CTL.
        if let atl = today.atl, let ctl = today.ctl, ctl > 0 {
            let ratio = atl / ctl
            let verdict: Readiness.Signal.Verdict = ratio > 1.3 ? .above : .typical
            let w: Double = ratio > 1.5 ? -8 : (ratio > 1.3 ? -4 : 0)
            score += w
            signals.append(.init(name: "fatigue", verdict: verdict, value: atl, baseline: 0...(ctl * 1.3), weight: w))
        }

        // Athlete's own words carry real weight: heavy legs after a hard block beat any single metric.
        if let legs = feedback?.legs {
            let w: Double
            let verdict: Readiness.Signal.Verdict
            switch legs {
            case .heavy: w = -16; verdict = .below
            case .ok: w = 0; verdict = .typical
            case .fresh: w = 6; verdict = .above
            }
            score += w
            signals.append(.init(name: "legs", verdict: verdict, weight: w))
        }
        if let motivation = feedback?.motivation {
            let w = Double(motivation - 3) * 2
            score += w
            signals.append(.init(name: "motivation", verdict: motivation <= 2 ? .below : (motivation >= 4 ? .above : .typical), value: Double(motivation), weight: w))
        }

        // Low information: never claim "strong" with fewer than two real signals.
        let informed = signals.filter { $0.verdict != .missing }.count
        if informed < 2 { score = min(score, 60) }

        let clamped = Int(min(max(score, 0), 100).rounded())
        let level: Readiness.Level
        switch clamped {
        case 70...: level = .strong
        case 45..<70: level = .normal
        case 25..<45: level = .easy
        default: level = .rest
        }
        return Readiness(level: level, score: clamped, signals: signals, missingData: missing, summary: Self.summary(level: level, signals: signals))
    }

    /// Mean ± 1 SD of the recent values; nil when there are too few samples to call anything "typical".
    func typicalRange(_ values: [Double]) -> ClosedRange<Double>? {
        guard values.count >= 7 else { return nil }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count - 1)
        let sd = variance.squareRoot()
        return (mean - sd)...(mean + sd)
    }

    static func summary(level: Readiness.Level, signals: [Readiness.Signal]) -> String {
        let negatives = signals.filter { $0.weight < 0 }.map(\.name)
        switch level {
        case .rest: return "Several recovery signals are below your range (\(negatives.joined(separator: ", "))). Today is for rest or a very short spin."
        case .easy: return "Recovery is below usual (\(negatives.joined(separator: ", "))). Keep today easy and protect the key sessions."
        case .normal: return "Recovery is within your usual range. A normal training day."
        case .strong: return "Recovery is above your usual range. Good day for the hard session."
        }
    }
}
