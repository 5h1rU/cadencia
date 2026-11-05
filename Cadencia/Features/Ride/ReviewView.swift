import SwiftUI
import CadenciaCore

/// Post-ride: what happened, how it felt, and where the file is on its way to.
struct ReviewView: View {
    @Environment(AppModel.self) private var model
    let ride: RideRecording
    let done: () -> Void

    @State private var rpe: Int
    @State private var legs: SubjectiveFeedback.Legs?
    @State private var submitted = false
    /// The newest saved copy the screen has shown. While a memory warning keeps the ride out of the cache, the
    /// screen shows this copy instead of the recording from the end of the ride, so nothing it showed disappears.
    @State private var shownRide: RideRecording?

    /// Seeds the RPE once, from the workout. Seeding on appear would undo the rider's pick every time the
    /// RPE picker pops back to this screen.
    init(ride: RideRecording, done: @escaping () -> Void) {
        self.ride = ride
        self.done = done
        _rpe = State(initialValue: Self.defaultRPE(for: ride.workout))
    }

    private var ftp: Int { model.workingFTP ?? 200 }
    private var entry: UploadEntry? { model.state.ledger.entry(for: ride.id) }
    /// The saved recording: Intervals' analysis, the debrief and the feedback land here while the screen is open.
    private var current: RideRecording { model.cachedRide(id: ride.id) ?? shownRide ?? ride }
    /// The model is still saving the ride, writing it to Health or making the first upload attempt.
    private var finishing: Bool { model.finishingRides.contains(ride.id) }
    /// Intervals' numbers are on their way: the save, the upload or the analysis read is in flight.
    private var statsPending: Bool {
        current.analysis?.analyzed != true
            && (finishing || model.isUploading || model.debriefStatus[ride.id] == .waitingForIntervals)
    }

    var body: some View {
        List {
            Section {
                RideStatsRow(ride: current, ftp: ftp)
                    .redacted(reason: statsPending ? .placeholder : [])
                if adherence < 0.9 {
                    Label("Power ran \(Format.percent(1 - adherence)) under target on average. Worth a word to the coach if it felt harder than it should.", systemImage: "info.circle")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } header: {
                Text(ride.workout.name)
            }

            DebriefSections(ride: current)

            InfoSection {
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
            } information: {
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
                        if finishing || model.isUploading, entry.state == .pending || entry.state == .uncertain {
                            ProgressView()
                        } else {
                            Image(systemName: entry.state.symbol).foregroundStyle(entry.state == .confirmed ? .green : .secondary)
                        }
                    }
                } else {
                    HStack { ProgressView(); Text("Saving…").foregroundStyle(.secondary) }
                }
                // Only once the save happened: it runs after the ride file, and it can fail.
                if model.healthSavedRides.contains(ride.id) {
                    Label("Saved to Apple Health", systemImage: "heart.text.square")
                }
            }

            Section {
                Button {
                    guard !submitted else { return }
                    submitted = true
                    // The model finishes the save and the Intervals sync after the cover is gone.
                    let model = model, rideID = ride.id, rpe = rpe, legs = legs
                    Task { await model.submitReview(rideID: rideID, rpe: rpe, legs: legs) }
                    done()
                } label: {
                    Text("Done").font(.headline).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(submitted)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                .listRowSeparator(.hidden)
            }
            .listRowBackground(Color.clear)
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Ride complete")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
        // A memory warning can drop the saved recording from the cache: read it back off the main actor.
        .task(id: model.cachedRide(id: ride.id) == nil) { await model.loadRide(id: ride.id) }
        // Each newer copy becomes the fallback, so a purge never shows older data than the screen already showed.
        .onChange(of: model.cachedRide(id: ride.id), initial: true) { _, latest in
            if let latest { shownRide = latest }
        }
    }

    private var adherence: Double {
        let pairs = ride.samples.compactMap { s -> (Double, Double)? in
            guard let w = s.watts, let t = s.targetWatts, t > 0 else { return nil }
            return (Double(w), Double(t))
        }
        guard !pairs.isEmpty else { return 1 }
        return pairs.reduce(0) { $0 + $1.0 } / pairs.reduce(0) { $0 + $1.1 }
    }

    private static func defaultRPE(for workout: Workout) -> Int {
        switch workout.averageIntensity {
        case ..<0.6: return 3
        case ..<0.75: return 5
        case ..<0.9: return 7
        default: return 8
        }
    }
}

#Preview {
    NavigationStack { ReviewView(ride: PreviewData.ride) {} }.environment(PreviewData.model())
}
