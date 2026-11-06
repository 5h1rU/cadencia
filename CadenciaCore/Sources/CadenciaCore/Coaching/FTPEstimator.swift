import Foundation

public struct FTPEstimate: Codable, Equatable, Sendable {
    public enum Confidence: String, Codable, Sendable { case low, moderate, high }

    public var watts: Int
    public var confidence: Confidence
    public var sustainedEfforts: Int   // number of qualifying efforts (≥ 12 min) in the window
    public var basis: String           // which curve point / model produced the number
    public var windowDays: Int

    public init(watts: Int, confidence: Confidence, sustainedEfforts: Int, basis: String, windowDays: Int) {
        self.watts = watts
        self.confidence = confidence
        self.sustainedEfforts = sustainedEfforts
        self.basis = basis
        self.windowDays = windowDays
    }
}

/// Best mean-maximal power over `seconds`, as Intervals.icu's power curve reports it.
public struct PowerCurvePoint: Codable, Equatable, Sendable {
    public var seconds: Int
    public var watts: Int
    public init(seconds: Int, watts: Int) {
        self.seconds = seconds
        self.watts = watts
    }
}

/// Estimates FTP from the recent mean-maximal power curve.
///
/// Uses the strongest of three well-known approximations, each only when its input exists:
/// - 95 % of the best 20-minute power,
/// - the best 60-minute power itself,
/// - critical power from the 2-parameter model fitted on the best 3- and 12-minute efforts.
/// Confidence depends on how many sustained (≥ 12 min) efforts are in the window, which the
/// caller derives from activities with `estimatedFTP` or long high-intensity intervals.
public struct FTPEstimator: Sendable {
    public init() {}

    /// Intervals' own eFTP, preferred over the curve heuristics: the rolling FTP on the newest cycling
    /// activity in the window (`icu_rolling_ftp`), else the newest daily Ride eFTP from wellness. Both are
    /// Intervals' fit of the same 42-day power curve the heuristics read, so the numbers are comparable;
    /// the per-activity `icu_pm_ftp` is not (one ride's curve) and stays a corroboration signal only.
    public static func intervalsEFTP(activities: [ActivitySummary], wellness: [WellnessDay], today: Day, windowDays: Int = 42) -> Int? {
        let since = today.adding(days: -windowDays)
        if let rolling = activities.filter({ $0.isCycling && $0.day >= since && $0.day <= today && ($0.rollingFTP ?? 0) > 0 })
            .max(by: { $0.startDateLocal < $1.startDateLocal })?.rollingFTP {
            return rolling
        }
        return wellness.last { $0.day >= since && $0.day <= today && ($0.estimatedFTP ?? 0) > 0 }?.estimatedFTP.map { Int($0.rounded()) }
    }

    /// Intervals' eFTP when there is one; otherwise the strongest curve heuristic below.
    public func estimate(curve: [PowerCurvePoint], sustainedEfforts: Int, intervalsEFTP: Int?, windowDays: Int = 42) -> FTPEstimate? {
        guard let intervalsEFTP, intervalsEFTP > 0 else { return estimate(curve: curve, sustainedEfforts: sustainedEfforts, windowDays: windowDays) }
        return FTPEstimate(watts: intervalsEFTP, confidence: Self.confidence(sustainedEfforts), sustainedEfforts: sustainedEfforts,
                           basis: "Intervals.icu eFTP", windowDays: windowDays)
    }

    static func confidence(_ sustainedEfforts: Int) -> FTPEstimate.Confidence {
        switch sustainedEfforts {
        case ..<2: return .low
        case 2...4: return .moderate
        default: return .high
        }
    }

    public func estimate(curve: [PowerCurvePoint], sustainedEfforts: Int, windowDays: Int = 42) -> FTPEstimate? {
        let byDuration = Dictionary(curve.map { ($0.seconds, $0.watts) }, uniquingKeysWith: max)
        var candidates: [(watts: Double, basis: String)] = []

        if let p20 = byDuration[1200] { candidates.append((Double(p20) * 0.95, "95 % of best 20 min")) }
        if let p60 = byDuration[3600] { candidates.append((Double(p60), "best 60 min")) }
        if let p3 = byDuration[180], let p12 = byDuration[720], p12 < p3 {
            // W = CP·t + W′ for two points → CP = (W1 − W2)/(t1 − t2) with W = P·t.
            let w1 = Double(p3) * 180, w2 = Double(p12) * 720
            let cp = (w2 - w1) / (720 - 180)
            if cp > 0 { candidates.append((cp, "critical power (3/12 min)")) }
        }
        guard let best = candidates.max(by: { $0.watts < $1.watts }) else { return nil }
        return FTPEstimate(watts: Int(best.watts.rounded()), confidence: Self.confidence(sustainedEfforts), sustainedEfforts: sustainedEfforts,
                           basis: best.basis, windowDays: windowDays)
    }

    /// Decide whether to propose a working-FTP change. Only propose increases ≥ 2 % or decreases ≥ 5 %
    /// with at least moderate confidence; tiny changes just churn zones.
    ///
    /// A higher best effort is real evidence, so increases need nothing else. A lower curve only shows the
    /// athlete has not gone all out lately (normal in a base block), so a decrease is proposed only when
    /// Intervals' own per-ride eFTP over the same window (`recentEFTP`, the best of them) is also ≥ 5 % below.
    public func proposal(current: Int, estimate: FTPEstimate, recentEFTP: Int? = nil) -> Int? {
        guard estimate.confidence != .low else { return nil }
        func delta(_ watts: Int) -> Double { Double(watts - current) / Double(max(current, 1)) }
        if delta(estimate.watts) >= 0.02 { return estimate.watts }
        if delta(estimate.watts) <= -0.05, let recentEFTP, delta(recentEFTP) <= -0.05 { return estimate.watts }
        return nil
    }
}
