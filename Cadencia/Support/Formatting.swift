import SwiftUI
import CadenciaCore

enum Format {
    static func minutes(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 { return m > 0 ? "\(h) h \(m) min" : "\(h) h" }
        return "\(m) min"
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(Int(seconds.rounded()), 0)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    static func hours(_ seconds: Int) -> String {
        let h = Double(seconds) / 3600
        return String(format: "%.1f h", h)
    }

    static func percent(_ fraction: Double) -> String { "\(Int((fraction * 100).rounded())) %" }

    static func watts(_ w: Int?) -> String { w.map { "\($0) W" } ?? "–" }

    static func day(_ day: Day, style: Date.FormatStyle = .dateTime.weekday(.wide).day().month(.wide)) -> String {
        day.date().formatted(style)
    }

    static func shortDay(_ day: Day) -> String { day.date().formatted(.dateTime.weekday(.abbreviated).day()) }

    static func relative(_ date: Date?) -> String {
        guard let date else { return String(localized: "never") }
        return date.formatted(.relative(presentation: .named))
    }
}

extension SessionKind {
    var title: LocalizedStringKey {
        switch self {
        case .rest: return "Rest"
        case .recovery: return "Recovery spin"
        case .endurance: return "Endurance"
        case .tempo: return "Tempo"
        case .threshold: return "Threshold"
        case .vo2max: return "VO₂max"
        case .openerActivation: return "Opener"
        case .longRide: return "Long ride"
        case .groupRide: return "Group ride"
        case .race: return "Race"
        case .strength: return "Strength"
        }
    }

    var symbol: String {
        switch self {
        case .rest: return "bed.double"
        case .recovery: return "leaf"
        case .endurance: return "figure.outdoor.cycle"
        case .tempo: return "gauge.with.dots.needle.50percent"
        case .threshold: return "gauge.with.dots.needle.67percent"
        case .vo2max: return "flame"
        case .openerActivation: return "bolt"
        case .longRide: return "road.lanes"
        case .groupRide: return "person.3"
        case .race: return "flag.checkered"
        case .strength: return "dumbbell"
        }
    }

    var tint: Color {
        switch self {
        case .rest, .recovery: return .green
        case .endurance, .longRide, .groupRide: return .blue
        case .tempo, .openerActivation: return .orange
        case .threshold, .vo2max, .race: return .red
        case .strength: return .purple
        }
    }
}

extension Readiness.Level {
    var title: LocalizedStringKey {
        switch self {
        case .rest: return "Rest"
        case .easy: return "Go easy"
        case .normal: return "Ready"
        case .strong: return "Go hard"
        }
    }

    var tint: Color {
        switch self {
        case .rest: return .red
        case .easy: return .orange
        case .normal: return .green
        case .strong: return .mint
        }
    }

    var symbol: String {
        switch self {
        case .rest: return "moon.zzz"
        case .easy: return "tortoise"
        case .normal: return "checkmark.circle"
        case .strong: return "bolt.heart"
        }
    }
}

extension Readiness.Signal {
    var title: LocalizedStringKey {
        switch name {
        case "hrv": return "HRV"
        case "sleep": return "Sleep"
        case "restingHR": return "Resting HR"
        case "form": return "Form"
        case "fatigue": return "Fatigue"
        case "legs": return "Legs"
        case "motivation": return "Motivation"
        default: return LocalizedStringKey(name)
        }
    }

    var valueText: String {
        guard let value else { return "–" }
        switch name {
        case "sleep": return Format.hours(Int(value))
        case "hrv": return String(format: "%.0f ms", value)
        case "restingHR": return String(format: "%.0f bpm", value)
        case "form": return String(format: "%+.0f", value)
        default: return String(format: "%.0f", value)
        }
    }

    var verdictText: LocalizedStringKey {
        switch verdict {
        case .below: return "below usual"
        case .typical: return "in range"
        case .above: return "above usual"
        case .missing: return "no data"
        }
    }

    var verdictTint: Color {
        switch verdict {
        case .missing: return .secondary
        case .typical: return .green
        case .below: return name == "restingHR" || name == "fatigue" ? .green : .orange
        case .above: return name == "restingHR" || name == "fatigue" ? .orange : .green
        }
    }
}

extension GoalKind {
    var title: LocalizedStringKey {
        switch self {
        case .climbing: return "Climb better"
        case .ftp: return "Raise FTP"
        case .durability: return "Durability"
        case .endurance: return "Endurance"
        case .strength: return "Strength"
        case .event: return "Prepare an event"
        }
    }

    var subtitle: LocalizedStringKey {
        switch self {
        case .climbing: return "Sustained power at low cadence and repeated efforts"
        case .ftp: return "Threshold blocks with enough recovery to absorb them"
        case .durability: return "Hold power deep into long rides"
        case .endurance: return "Volume in zone 2, intensity only when fresh"
        case .strength: return "Gym sessions alongside the bike"
        case .event: return "Build, peak and taper for a date"
        }
    }

    var symbol: String {
        switch self {
        case .climbing: return "mountain.2"
        case .ftp: return "chart.line.uptrend.xyaxis"
        case .durability: return "battery.100percent"
        case .endurance: return "figure.outdoor.cycle"
        case .strength: return "dumbbell"
        case .event: return "flag.checkered"
        }
    }
}

extension TrainingPhase.Focus {
    var title: LocalizedStringKey {
        switch self {
        case .prepare: return "Prepare"
        case .base: return "Base"
        case .build: return "Build"
        case .peak: return "Peak"
        case .taper: return "Taper"
        case .consolidate: return "Consolidate"
        case .recover: return "Recover"
        }
    }
}

extension UploadEntry.State {
    var title: LocalizedStringKey {
        switch self {
        case .pending: return "Pending"
        case .uncertain: return "Checking"
        case .needsReconnect: return "Needs reconnect"
        case .confirmed: return "In Intervals"
        }
    }

    var symbol: String {
        switch self {
        case .pending: return "clock"
        case .uncertain: return "questionmark.circle"
        case .needsReconnect: return "person.crop.circle.badge.exclamationmark"
        case .confirmed: return "checkmark.icloud"
        }
    }
}
