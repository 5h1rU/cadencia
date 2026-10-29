import SwiftUI
import CadenciaCore

/// A structured session block by block, with the reasoning that produced it.
struct WorkoutDetailView: View {
    let workout: Workout
    let ftp: Int

    private var ceilingWatts: Int? { workout.intensityCeiling.map { Int(($0 * Double(ftp)).rounded()) } }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    WorkoutProfileView(workout: workout, ftp: ftp, ceilingWatts: ceilingWatts)
                        .frame(height: 200)
                    HStack(spacing: 0) {
                        stat("Duration", Format.minutes(workout.totalDuration))
                        stat("Load", "\(workout.estimatedLoad) TSS")
                        stat("IF", String(format: "%.2f", workout.averageIntensity))
                        stat("Work", "\(Int((workout.averageIntensity * Double(ftp) * workout.totalDuration / 1000).rounded())) kJ")
                        if let c = ceilingWatts { stat("Ceiling", "\(c) W") }
                    }
                }
                .padding(.vertical, 4)
            } footer: {
                Text("Dashed line: FTP \(ftp) W. Red line: today's ceiling; ERG never pushes above it. Colors are power zones.")
            }

            Section("Why this session") {
                Text(workout.rationale)
            }

            Section {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow {
                        Text("At").gridColumnAlignment(.trailing)
                        Text("Block")
                        Text("Length").gridColumnAlignment(.trailing)
                        Text("Target").gridColumnAlignment(.trailing)
                        Text("% FTP").gridColumnAlignment(.trailing)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    Divider()
                    ForEach(Array(rows.enumerated()), id: \.element.step.id) { i, row in
                        GridRow {
                            Text(Format.clock(row.start)).monospacedDigit().foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 6) {
                                    Circle().fill(Zone.color(for: row.step.startIntensity)).frame(width: 8, height: 8)
                                    Text(row.step.name)
                                }
                                HStack(spacing: 4) {
                                    Text(Zone.name(for: (row.step.startIntensity + row.step.endIntensity) / 2))
                                    if let rpm = row.step.cadenceRPM { Text("· \(rpm) rpm") }
                                }
                                .font(.caption2).foregroundStyle(.secondary)
                            }
                            Text(Format.minutes(row.step.duration)).monospacedDigit()
                            Text(targetText(row.step)).monospacedDigit()
                            Text(percentText(row.step)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .font(.subheadline)
                        if i < rows.count - 1 { Divider() }
                    }
                }
            } header: {
                Text("Blocks")
            } footer: {
                if workout.steps.contains(where: \.isRamp) {
                    Text("Ramps show start→end watts; the trainer moves the target every second between them.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(workout.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private struct Row { let step: WorkoutStep; let start: TimeInterval }

    private var rows: [Row] {
        var t: TimeInterval = 0
        return workout.steps.map { step in
            defer { t += step.duration }
            return Row(step: step, start: t)
        }
    }

    private func stat(_ title: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.semibold).monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func watts(_ i: Double) -> Int { Int((i * Double(ftp)).rounded()) }

    private func targetText(_ step: WorkoutStep) -> String {
        step.isRamp ? "\(watts(step.startIntensity))→\(watts(step.endIntensity)) W" : "\(watts(step.startIntensity)) W"
    }

    private func percentText(_ step: WorkoutStep) -> String {
        let a = Int((step.startIntensity * 100).rounded()), b = Int((step.endIntensity * 100).rounded())
        return step.isRamp ? "\(a)→\(b)" : "\(a)"
    }
}

#Preview {
    NavigationStack { WorkoutDetailView(workout: PreviewData.state.today!.workout, ftp: 240) }
}
