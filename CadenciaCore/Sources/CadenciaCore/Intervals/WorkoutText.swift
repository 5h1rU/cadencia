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
    public static func render(_ workout: Workout, ftp: Int? = nil) -> String {
        var blocks: [String] = []
        for step in workout.steps {
            let start = min(step.startIntensity, workout.intensityCeiling ?? step.startIntensity)
            let end = min(step.endIntensity, workout.intensityCeiling ?? step.endIntensity)
            func target(_ intensity: Double) -> String {
                if let ftp { return String(Int((intensity * Double(ftp) + 0.000001).rounded(.down))) }
                // Floor capped percentages so rounding cannot lift a target above the ceiling.
                if workout.intensityCeiling != nil { return String(Int((intensity * 100 + 0.000001).rounded(.down))) }
                return String(percent(intensity))
            }
            let unit = ftp == nil ? "%" : "w"
            var line = "- \(duration(step.duration)) "
            if abs(start - end) > 0.001 {
                line += "ramp \(target(start))-\(target(end))\(unit)"
            } else {
                line += "\(target(start))\(unit)"
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
