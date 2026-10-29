import SwiftUI
import Charts
import CadenciaCore

/// Power profile of a structured workout: time on X (minutes), watts on Y, every block drawn at its
/// exact target, ramps as slopes, colored by zone, with the FTP line and (optionally) today's ceiling.
/// `compact` drops axis labels and block annotations for the Today card.
struct WorkoutProfileView: View {
    let workout: Workout
    let ftp: Int
    var ceilingWatts: Int? = nil
    var compact = false

    private struct Block: Identifiable {
        let id: UUID
        let name: String
        let startMin: Double
        let endMin: Double
        let startWatts: Double
        let endWatts: Double
        let intensity: Double
        var isRamp: Bool { abs(startWatts - endWatts) > 0.5 }
        var midMin: Double { (startMin + endMin) / 2 }
    }

    private var blocks: [Block] {
        var t = 0.0
        return workout.steps.map { step in
            let b = Block(id: step.id, name: step.name, startMin: t, endMin: t + step.duration / 60,
                          startWatts: step.startIntensity * Double(ftp), endWatts: step.endIntensity * Double(ftp),
                          intensity: (step.startIntensity + step.endIntensity) / 2)
            t += step.duration / 60
            return b
        }
    }

    private var totalMinutes: Double { max(workout.totalDuration / 60, 1) }

    private var yMax: Double {
        let peak = blocks.map { max($0.startWatts, $0.endWatts) }.max() ?? Double(ftp)
        return max(peak, Double(ftp), Double(ceilingWatts ?? 0)) * 1.12
    }

    var body: some View {
        let blocks = blocks
        let total = totalMinutes
        Chart {
            ForEach(blocks) { b in
                if b.isRamp {
                    AreaMark(x: .value("Time", b.startMin), y: .value("Watts", b.startWatts),
                             series: .value("Block", b.id.uuidString), stacking: .unstacked)
                        .foregroundStyle(Zone.color(for: b.intensity).opacity(0.85))
                        .interpolationMethod(.linear)
                    AreaMark(x: .value("Time", b.endMin), y: .value("Watts", b.endWatts),
                             series: .value("Block", b.id.uuidString), stacking: .unstacked)
                        .foregroundStyle(Zone.color(for: b.intensity).opacity(0.85))
                        .interpolationMethod(.linear)
                } else {
                    RectangleMark(xStart: .value("Start", b.startMin), xEnd: .value("End", b.endMin),
                                  yStart: .value("Zero", 0), yEnd: .value("Watts", b.startWatts))
                        .foregroundStyle(Zone.color(for: b.intensity).opacity(0.85))
                        .annotation(position: .overlay, alignment: .top) {
                            if !compact, (b.endMin - b.startMin) / total >= 0.09 {
                                Text("\(Int(b.startWatts.rounded())) W")
                                    .font(.caption2.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(.white)
                                    .padding(.top, 2)
                            }
                        }
                }
            }
            RuleMark(y: .value("FTP", Double(ftp)))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .foregroundStyle(.secondary)
                .annotation(position: .top, alignment: .trailing) {
                    if !compact { Text("FTP \(ftp) W").font(.caption2).foregroundStyle(.secondary) }
                }
            if let c = ceilingWatts, c > 0 {
                RuleMark(y: .value("Ceiling", Double(c)))
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .foregroundStyle(.red.opacity(0.8))
                    .annotation(position: .top, alignment: .leading) {
                        if !compact { Text("Ceiling \(c) W").font(.caption2).foregroundStyle(.red) }
                    }
            }
        }
        .chartXScale(domain: 0...total)
        .chartYScale(domain: 0...yMax)
        .chartXAxis(compact ? .hidden : .automatic)
        .chartYAxis(compact ? .hidden : .automatic)
        .chartXAxis {
            AxisMarks(values: .stride(by: xStride(total))) { value in
                AxisGridLine()
                AxisTick()
                AxisValueLabel {
                    if let m = value.as(Double.self) { Text("\(Int(m)) min").font(.caption2) }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let w = value.as(Double.self) { Text("\(Int(w)) W").font(.caption2) }
                }
            }
        }
        .chartLegend(.hidden)
    }

    private func xStride(_ total: Double) -> Double {
        switch total {
        case ..<45: return 5
        case ..<100: return 10
        case ..<200: return 20
        default: return 30
        }
    }
}

/// Coggan power zones as fractions of FTP, used for color only.
enum Zone {
    static func color(for intensity: Double) -> Color {
        switch intensity {
        case ..<0.55: return .gray
        case ..<0.75: return .blue
        case ..<0.90: return .green
        case ..<1.05: return .yellow
        case ..<1.20: return .orange
        default: return .red
        }
    }

    /// "Z2 · 55–75 %": zone plus its FTP band, for legends.
    static func shortName(for intensity: Double) -> String {
        switch intensity {
        case ..<0.55: return "Z1 <55 %"
        case ..<0.75: return "Z2 55–75 %"
        case ..<0.90: return "Z3 75–90 %"
        case ..<1.05: return "Z4 90–105 %"
        case ..<1.20: return "Z5 105–120 %"
        default: return "Z6 >120 %"
        }
    }

    static func name(for intensity: Double) -> LocalizedStringKey {
        switch intensity {
        case ..<0.55: return "Z1 Recovery"
        case ..<0.75: return "Z2 Endurance"
        case ..<0.90: return "Z3 Tempo"
        case ..<1.05: return "Z4 Threshold"
        case ..<1.20: return "Z5 VO₂max"
        default: return "Z6 Anaerobic"
        }
    }
}

#Preview("Full") {
    VStack {
        WorkoutProfileView(workout: PreviewData.state.today!.workout, ftp: 240, ceilingWatts: 182).frame(height: 220).padding()
        WorkoutProfileView(workout: Workout(name: "Threshold", kind: .threshold, steps: [
            WorkoutStep(name: "Warm-up", duration: 900, startIntensity: 0.45, endIntensity: 0.75),
            WorkoutStep(name: "Threshold", duration: 1200, intensity: 0.98), WorkoutStep(name: "Recovery", duration: 300, intensity: 0.55),
            WorkoutStep(name: "Threshold", duration: 1200, intensity: 0.98), WorkoutStep(name: "Cool-down", duration: 600, startIntensity: 0.6, endIntensity: 0.4),
        ], intensityCeiling: 1.05, rationale: ""), ftp: 240, ceilingWatts: 252).frame(height: 220).padding()
    }
}

#Preview("Compact") {
    WorkoutProfileView(workout: PreviewData.state.today!.workout, ftp: 240, compact: true).frame(height: 56).padding()
}
