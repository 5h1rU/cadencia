import Foundation

/// Product-wide checks on the coach's stated purpose. These are conservative bounds, not workout
/// templates or readiness thresholds. The coach still chooses the dose from each athlete's evidence.
public struct PrescriptionValidator: Sendable {
    public var activationIntensity: Double = 0.9
    public var easyRecoveryIntensity: Double = 0.6
    public var easyRidingIntensity: Double = 0.75
    public var maxContinuousActivation: TimeInterval = 3 * 60
    public var maxActivationFraction: Double = 0.2

    public init() {}

    public func validate(_ prescription: DailyPrescription, brief: CoachBrief? = nil) throws {
        let workout = prescription.workout
        func reject(_ reason: String) throws {
            throw DailyPrescription.ValidationError.sessionIntent(reason)
        }
        if workout.kind == .rest, !workout.steps.isEmpty {
            try reject("A rest day must have no riding blocks.")
        }
        if let outlook = prescription.week.first(where: { $0.day.iso == brief?.today }), outlook.kind != workout.kind {
            try reject("Today's week entry must have the same purpose as today's concrete workout.")
        }
        guard workout.kind == .openerActivation else { return }
        if let brief {
            let events = [brief.upcomingEvent, brief.plan?.event].compactMap { $0 }
            guard let today = Day(iso: brief.today), events.contains(where: { Day(iso: $0.day) == today.adding(days: 1) }) else {
                try reject("An opener requires a confirmed event the following day. Choose the actual training purpose otherwise.")
                return
            }
        }

        // Split ramps exactly where they cross the relevant zones, then merge adjacent work. Splitting
        // a long effort into multiple JSON steps must not bypass the continuous-duration limit.
        let slices = workout.steps.flatMap { self.slices(for: $0) }
        let activation = slices.filter { $0.kind == .activation }.reduce(0) { $0 + $1.seconds }
        guard activation > 0 else {
            try reject("An opener needs brief near-threshold or above-threshold activation. Label an easy-only alternative endurance or recovery and explain why.")
            return
        }
        let nonEasy = slices.filter { $0.kind == .activation || $0.kind == .other }.reduce(0) { $0 + $1.seconds }
        if nonEasy >= workout.totalDuration / 2 {
            try reject("An opener must be mostly easy riding, not a sustained tempo or threshold session with brief efforts added.")
        }
        if slices.first?.kind == .activation {
            try reject("Include an easy warm-up before the first activation.")
        }
        guard activation <= workout.totalDuration * maxActivationFraction + 0.001 else {
            try reject("Activation occupies too much of the opener. Reduce intensity exposure and preserve mostly easy riding.")
            return
        }
        var effort: TimeInterval = 0
        var recovery: TimeInterval = 0
        for slice in slices {
            if slice.kind == .activation {
                if effort > 0, recovery > 0 {
                    guard recovery + 0.001 >= effort else {
                        try reject("Give each activation at least its own duration in easy recovery before the next effort.")
                        return
                    }
                    effort = 0; recovery = 0
                }
                effort += slice.seconds
                if effort > maxContinuousActivation + 0.001 {
                    try reject("An opener activation is too long. Use brief efforts, not sustained training intervals.")
                }
            } else if slice.kind == .easy, effort > 0 {
                recovery += slice.seconds
            }
        }
        if recovery + 0.001 < effort {
            try reject("Finish the final activation with full easy recovery and a cool-down.")
        }
    }

    private enum Kind { case activation, easy, endurance, other }
    private struct Slice { var kind: Kind; var seconds: TimeInterval }

    private func slices(for step: WorkoutStep) -> [Slice] {
        let a = step.startIntensity, b = step.endIntensity
        var fractions = [0.0, 1.0]
        if a != b {
            for threshold in [activationIntensity, easyRecoveryIntensity, easyRidingIntensity] {
                let crossing = (threshold - a) / (b - a)
                if crossing > 0, crossing < 1 { fractions.append(crossing) }
            }
        }
        fractions.sort()
        return zip(fractions, fractions.dropFirst()).map { start, end in
            let intensity = a + (b - a) * (start + end) / 2
            let kind: Kind = intensity >= activationIntensity ? .activation
                : (intensity <= easyRecoveryIntensity ? .easy : (intensity <= easyRidingIntensity ? .endurance : .other))
            return Slice(kind: kind, seconds: (end - start) * step.duration)
        }
    }
}
