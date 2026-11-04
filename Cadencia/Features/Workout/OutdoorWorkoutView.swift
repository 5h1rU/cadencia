import SwiftUI
import CadenciaCore

/// Prepare today's current prescription for a head unit. Calendar acknowledgement and actual
/// device receipt are deliberately separate; changing the prescription invalidates the export.
struct OutdoorWorkoutView: View {
    @Environment(AppModel.self) private var model
    @State private var busy = false
    @State private var error: String?
    @State private var fitFile: URL?

    var body: some View {
        List {
            if model.isTodayWorkoutCompleted {
                Section {
                    if let ride = model.completedRideToday {
                        NavigationLink { RideDebriefView(rideID: ride.id) } label: {
                            Label("Completed", systemImage: "checkmark.circle.fill")
                        }
                    } else {
                        Label("Completed", systemImage: "checkmark.circle.fill")
                    }
                }
            } else if let prepared = model.outdoorWorkout {
                InfoSection {
                    Text(prepared.workout.name).font(.headline)
                    LabeledContent("Duration", value: Format.minutes(prepared.workout.totalDuration))
                    LabeledContent("Outdoor FTP", value: "\(prepared.ftp) W")
                    if let ceiling = prepared.workout.intensityCeiling {
                        LabeledContent("Ceiling", value: "\(watts(ceiling, ftp: prepared.ftp)) W")
                    }
                } header: {
                    Text("Session")
                } information: {
                    Text("Outdoor targets preserve today's readiness limits. Changing FTP or riding outdoors never raises this prescription's power.")
                }

                Section {
                    NavigationLink { PlannedRideRouteView(day: model.today) } label: {
                        Label(model.plannedToday?.route == nil ? "Add a route (optional)" : "Review planned route", systemImage: "map")
                    }
                }

                Section {
                    Picker("Bike computer", selection: Binding(get: { model.state.settings.outdoorDevice }, set: { device in
                        model.updateSettings { $0.outdoorDevice = device }
                        error = nil
                    })) {
                        Text("Garmin Edge 8xx / 1xxx").tag(OutdoorDevice.garmin)
                        Text("Magene C6xx / C7xx").tag(OutdoorDevice.magene)
                    }
                }

                if model.state.settings.outdoorDevice == .garmin {
                    garminSection
                } else {
                    mageneSection(prepared)
                }

                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }
                blocksSection(prepared)
                returnSection
            } else {
                ContentUnavailableView("No outdoor workout", systemImage: "bicycle", description: Text("Ask the coach for today's cycling session first."))
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Ride outdoors")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Refresh", systemImage: "arrow.clockwise") { run { await model.refresh() } }
                    .disabled(busy || model.isSyncing)
            }
        }
        .onAppear {
            if model.todayRideLocation != .outdoor { model.setTodayRideLocation(.outdoor) }
        }
        .onChange(of: model.outdoorRevision) { _, _ in fitFile = nil }
        .onChange(of: model.isSignedIn) { _, _ in fitFile = nil }
    }

    private var garminSection: some View {
        InfoSection {
            Text("In Intervals.icu Settings, connect Garmin and enable Upload planned workouts. Then sync your Edge with Garmin Connect.")
                .font(.subheadline)
            Link("Open Intervals.icu settings", destination: URL(string: "https://intervals.icu/settings")!)
            Button {
                run { try await model.sendOutdoorWorkout() }
            } label: {
                HStack {
                    Label("Send workout via Intervals.icu", systemImage: "arrow.up.circle")
                    if busy { Spacer(); ProgressView() }
                }
            }
            .disabled(busy || !model.isSignedIn || model.coachThinking)
            if let handoff = model.currentOutdoorHandoff {
                Label("Saved in Intervals.icu", systemImage: "checkmark.circle").foregroundStyle(.green)
                Text(handoff.savedAt, format: .dateTime.hour().minute()).font(.caption).foregroundStyle(.secondary)
                Text("Sync Garmin Connect, then check the workout on your Edge before leaving. Cadencia cannot confirm receipt by the bike computer.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Button("Prepare Garmin FIT file", systemImage: "square.and.arrow.up") {
                run { fitFile = try await model.exportOutdoorFIT() }
            }
            .disabled(busy || !model.isSignedIn || model.coachThinking)
            if let fitFile, model.currentOutdoorHandoff != nil {
                ShareLink(item: fitFile) { Label("Share Garmin FIT file", systemImage: "square.and.arrow.up") }
                Text("For compatible Edge models, copy the FIT workout to Garmin/NewFiles over USB and restart the device. Sharing the file does not confirm installation.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("Transfer to Garmin")
        } information: {
            Text("Only the current prescription is sent. Send it again after the coach changes today's session, then sync the Edge again.")
        }
    }

    private func mageneSection(_ prepared: OutdoorWorkout) -> some View {
        InfoSection {
            Label("Manual setup required", systemImage: "hand.point.up.left")
            Text("Magene accepts structured workouts created in OnelapFit or synced from TrainingPeaks. A supported automatic connection from Cadencia is not available yet.")
                .font(.subheadline)
            Text("In OnelapFit, open your bike computer settings → Workouts → New Training. Recreate the blocks below, save, and sync to your C6xx or C7xx. Confirm the workout runs in outdoor mode with GPS on your firmware.")
                .font(.subheadline)
            ShareLink(item: prepared.workout.name + "\n" + model.today.iso + "\n\n" + prepared.text) {
                Label("Share workout instructions", systemImage: "square.and.arrow.up")
            }
            Link("Magene workout support", destination: URL(string: "https://www.onelap.com/faq.html")!)
        } header: {
            Text("Transfer to Magene")
        } information: {
            Text("FIT file import into OnelapFit is not verified. Cadencia cannot send workouts to TrainingPeaks or confirm installation on Magene yet.")
        }
    }

    private func blocksSection(_ prepared: OutdoorWorkout) -> some View {
        InfoSection {
            ForEach(prepared.workout.steps) { step in
                VStack(alignment: .leading, spacing: 4) {
                    Text(step.name).font(.subheadline.weight(.semibold))
                    HStack {
                        Text(Format.clock(step.duration)).monospacedDigit()
                        Spacer()
                        Text(target(step, ftp: prepared.ftp)).monospacedDigit()
                        if let rpm = step.cadenceRPM { Text("\(rpm) rpm").foregroundStyle(.secondary) }
                    }
                    .font(.footnote)
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("Outdoor blocks")
        } information: {
            Text("Ramps show start → end watts. Follow the targets as road conditions allow; the ceiling remains the upper limit.")
        }
    }

    private var returnSection: some View {
        Section {
            Text("Record on your bike computer. Let Garmin sync the ride to Intervals.icu; for Magene, export the recorded FIT from OnelapFit and import it into Intervals.icu. Pair it with this planned workout in Intervals, then refresh Cadencia for the coach's review.")
                .font(.subheadline)
            Link("Open Intervals.icu calendar", destination: URL(string: "https://intervals.icu")!)
        } header: {
            Text("After the ride")
        }
    }

    private func watts(_ intensity: Double, ftp: Int) -> Int { Int((intensity * Double(ftp) + 0.000001).rounded(.down)) }

    private func target(_ step: WorkoutStep, ftp: Int) -> String {
        let start = watts(step.startIntensity, ftp: ftp), end = watts(step.endIntensity, ftp: ftp)
        return start == end ? "\(start) W" : "\(start) → \(end) W"
    }

    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true
        error = nil
        Task { @MainActor in
            defer { busy = false }
            do { try await action() }
            catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }
}

#Preview {
    NavigationStack { OutdoorWorkoutView() }
        .environment(PreviewData.model(signedIn: false))
}
