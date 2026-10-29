import SwiftUI
import CadenciaCore

/// Post-ride: what happened, how it felt, and where the file is on its way to.
struct ReviewView: View {
    @Environment(AppModel.self) private var model
    let ride: RideRecording
    let done: () -> Void

    @State private var rpe: Int = 6
    @State private var legs: SubjectiveFeedback.Legs?
    @State private var submitted = false

    private var ftp: Int { model.workingFTP ?? 200 }
    private var entry: UploadEntry? { model.state.ledger.entry(for: ride.id) }

    var body: some View {
        List {
            Section {
                HStack(spacing: 16) {
                    stat("Time", Format.clock(ride.duration))
                    stat("Avg", Format.watts(ride.averageWatts))
                    stat("NP", Format.watts(ride.normalizedWatts))
                    stat("Load", ride.trainingLoad(ftp: ftp).map { "\($0)" } ?? "–")
                    stat("Avg HR", ride.averageHeartRate.map { "\($0)" } ?? "–")
                }
                .padding(.vertical, 4)
                if adherence < 0.9 {
                    Label("Power ran \(Format.percent(1 - adherence)) under target on average. Worth a word to the coach if it felt harder than it should.", systemImage: "info.circle")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } header: {
                Text(ride.workout.name)
            }

            Section {
                Picker("Effort (RPE)", selection: $rpe) {
                    ForEach(1...10, id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.navigationLink)
                Picker("Legs", selection: $legs) {
                    Text("Fresh").tag(SubjectiveFeedback.Legs?.some(.fresh))
                    Text("OK").tag(SubjectiveFeedback.Legs?.some(.ok))
                    Text("Heavy").tag(SubjectiveFeedback.Legs?.some(.heavy))
                }
                .pickerStyle(.segmented)
            } header: {
                Text("How was it?")
            } footer: {
                Text("RPE and feel go to Intervals with the activity and feed tomorrow's readiness.")
            }

            Section("Sync") {
                if let entry {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.state.title)
                            if let err = entry.lastError, entry.state != .confirmed { Text(err).font(.footnote).foregroundStyle(.secondary).lineLimit(2) }
                            if entry.state == .confirmed { Text("Activity \(entry.intervalsActivityID ?? "")").font(.footnote).foregroundStyle(.secondary) }
                        }
                    } icon: {
                        Image(systemName: entry.state.symbol).foregroundStyle(entry.state == .confirmed ? .green : .secondary)
                    }
                } else {
                    HStack { ProgressView(); Text("Saving…").foregroundStyle(.secondary) }
                }
                if model.state.settings.writeWorkoutsToHealth {
                    Label("Saved to Apple Health", systemImage: "heart.text.square")
                }
            }

            Section {
                Button {
                    Task {
                        await model.submitReview(rideID: ride.id, rpe: rpe, legs: legs)
                        submitted = true
                        done()
                    }
                } label: {
                    Text("Done").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            .listRowBackground(Color.clear)
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Ride complete")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
        .onAppear { rpe = defaultRPE }
    }

    private var adherence: Double {
        let pairs = ride.samples.compactMap { s -> (Double, Double)? in
            guard let w = s.watts, let t = s.targetWatts, t > 0 else { return nil }
            return (Double(w), Double(t))
        }
        guard !pairs.isEmpty else { return 1 }
        return pairs.reduce(0) { $0 + $1.0 } / pairs.reduce(0) { $0 + $1.1 }
    }

    private var defaultRPE: Int {
        let intensity = ride.workout.averageIntensity
        switch intensity {
        case ..<0.6: return 3
        case ..<0.75: return 5
        case ..<0.9: return 7
        default: return 8
        }
    }

    private func stat(_ title: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline.monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview {
    NavigationStack { ReviewView(ride: PreviewData.ride) {} }.environment(PreviewData.model())
}
