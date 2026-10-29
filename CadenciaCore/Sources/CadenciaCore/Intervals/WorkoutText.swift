import Foundation

/// Renders a `Workout` in Intervals.icu's workout-description syntax so a planned event created through
/// the API gets a structure, training load and time-in-zone on their side.
///
/// Example output:
/// ```
/// Warm-up
/// - 10m ramp 45-60%
///
/// Steady endurance
/// - 45m 65% 88rpm
/// ```
public enum WorkoutText {
    public static func render(_ workout: Workout) -> String {
        var blocks: [String] = []
        for step in workout.steps {
            var line = "- \(duration(step.duration)) "
            if step.isRamp {
                line += "ramp \(percent(step.startIntensity))-\(percent(step.endIntensity))%"
            } else {
                line += "\(percent(step.startIntensity))%"
            }
            if let rpm = step.cadenceRPM { line += " \(rpm)rpm" }
            blocks.append("\(step.name)\n\(line)")
        }
        var text = blocks.joined(separator: "\n\n")
        if !workout.rationale.isEmpty {
            text = "\(workout.rationale)\n\n" + text
        }
        return text
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let m = total / 60, s = total % 60
        if s == 0 { return "\(m)m" }
        if m == 0 { return "\(s)s" }
        return "\(m)m\(s)s"
    }

    static func percent(_ intensity: Double) -> Int { Int((intensity * 100).rounded()) }
}
