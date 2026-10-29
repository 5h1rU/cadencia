import SwiftUI
import CadenciaCore

/// A structured session block by block, with the reasoning that produced it.
struct WorkoutDetailView: View {
    let workout: Workout
    let ftp: Int

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    WorkoutProfileView(workout: workout).frame(height: 80)
                    HStack(spacing: 16) {
                        stat("Duration", Format.minutes(workout.totalDuration))
                        stat("Load", "\(workout.estimatedLoad)")
                        stat("IF", String(format: "%.2f", workout.averageIntensity))
                        if let c = workout.intensityCeiling { stat("Ceiling", Format.watts(Int((c * Double(ftp)).rounded()))) }
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Why this session") {
                Text(workout.rationale)
            }

            Section("Blocks") {
                ForEach(workout.steps) { step in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(step.name)
                            if let rpm = step.cadenceRPM { Text("\(rpm) rpm").font(.footnote).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(targetText(step)).monospacedDigit()
                            Text(Format.minutes(step.duration)).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(workout.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func stat(_ title: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline.monospacedDigit())
        }
    }

    private func targetText(_ step: WorkoutStep) -> String {
        let a = Int((step.startIntensity * Double(ftp)).rounded())
        let b = Int((step.endIntensity * Double(ftp)).rounded())
        return step.isRamp ? "\(a)→\(b) W" : "\(a) W · \(Format.percent(step.startIntensity))"
    }
}

#Preview {
    NavigationStack { WorkoutDetailView(workout: PreviewData.state.today!.workout, ftp: 240) }
}
