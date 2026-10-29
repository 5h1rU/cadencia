import SwiftUI
import CadenciaCore

/// Devices → ride → review, presented full screen from Today.
struct PreRideFlow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let workout: Workout
    let plannedSession: PlannedSession?

    @State private var ergEnabled = true
    @State private var session: RideSession?
    @State private var finished: RideRecording?

    var body: some View {
        NavigationStack {
            if let finished {
                ReviewView(ride: finished) { dismiss() }
            } else if let session {
                RideView(session: session) { recording in
                    finished = recording
                    Task { await model.finishRide(recording) }
                }
            } else {
                DevicesView(workout: workout, ergEnabled: $ergEnabled) {
                    Task {
                        let commentator = await model.rideCommentator()
                        session = RideSession(workout: workout, ftp: model.workingFTP ?? 200, athleteID: model.athleteID,
                                              plannedSessionID: plannedSession?.id, intervalsEventID: plannedSession?.intervalsEventID,
                                              bluetooth: model.bluetooth, ergEnabled: ergEnabled, commentator: commentator)
                    }
                } cancel: { dismiss() }
            }
        }
        .onAppear { ergEnabled = model.state.settings.ergByDefault }
        .interactiveDismissDisabled(session != nil && finished == nil)
    }
}

/// Pre-ride checklist: trainer, heart rate band, optional power meter, ERG toggle.
struct DevicesView: View {
    @Environment(AppModel.self) private var model
    let workout: Workout
    @Binding var ergEnabled: Bool
    let start: () -> Void
    let cancel: () -> Void

    @State private var pickingRole: BluetoothManager.Role?

    private var bt: BluetoothManager { model.bluetooth }

    var body: some View {
        List {
            Section {
                deviceRow(.trainer, title: "Smart trainer", symbol: "bicycle")
                deviceRow(.heartRate, title: "Heart rate", symbol: "heart")
                deviceRow(.powerMeter, title: "Power meter", symbol: "bolt.circle", optional: true)
            } header: {
                Text("Devices")
            } footer: {
                if !bt.isPoweredOn { Text("Turn on Bluetooth to find your devices.") }
                else if bt.trainer == nil { Text("Without a trainer you can still record with a power meter and heart rate band; targets will show on screen only.") }
            }

            Section {
                Toggle("ERG mode", isOn: $ergEnabled)
                    .disabled(bt.trainer == nil)
            } footer: {
                Text("ERG holds the target power for you. Off, the trainer keeps its own resistance and you ride to the numbers on screen.")
            }

            Section("Session") {
                HStack {
                    Image(systemName: workout.kind.symbol).foregroundStyle(workout.kind.tint)
                    VStack(alignment: .leading) {
                        Text(workout.name)
                        Text("\(Format.minutes(workout.totalDuration)) · \(workout.estimatedLoad) TSS").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 24) {
                    liveValue("Power", bt.live.watts.map { "\($0)" } ?? "–", unit: "W")
                    liveValue("HR", bt.live.heartRate.map { "\($0)" } ?? "–", unit: "bpm")
                    liveValue("Cadence", bt.live.cadence.map { "\($0)" } ?? "–", unit: "rpm")
                }
            }

            Section {
                Button { start() } label: {
                    Label("Start", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(bt.trainer?.isReady != true && bt.powerMeter?.isReady != true && bt.heartRateMonitor?.isReady != true)
            }
            .listRowBackground(Color.clear)
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Get ready")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { cancel() } } }
        .onAppear { bt.reconnectRemembered() }
        .sheet(item: $pickingRole) { role in DevicePickerView(role: role) }
    }

    private func deviceRow(_ role: BluetoothManager.Role, title: LocalizedStringKey, symbol: String, optional: Bool = false) -> some View {
        Button { pickingRole = role } label: {
            HStack {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                        if let c = bt.connections[role] {
                            HStack(spacing: 4) {
                                Text(c.name)
                                if let b = c.batteryPercent { Text("· \(b) %") }
                            }
                            .font(.footnote).foregroundStyle(.secondary)
                        } else {
                            Text(optional ? "Optional" : "Not connected").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                } icon: { Image(systemName: symbol) }
                Spacer()
                if let c = bt.connections[role] {
                    if c.isReady {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        ProgressView()
                    }
                } else {
                    Image(systemName: "plus.circle").foregroundStyle(.tint)
                }
            }
        }
        .foregroundStyle(.primary)
    }

    private func liveValue(_ title: LocalizedStringKey, _ value: String, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(.title3.monospacedDigit().weight(.semibold))
                Text(unit).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

/// Scans for devices advertising the service a role needs and connects the chosen one.
struct DevicePickerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let role: BluetoothManager.Role

    private var bt: BluetoothManager { model.bluetooth }
    private var candidates: [BluetoothManager.Discovered] { bt.discovered.filter { $0.roles.contains(role) } }

    var body: some View {
        NavigationStack {
            List {
                if let current = bt.connections[role] {
                    Section("Connected") {
                        LabeledContent(current.name) {
                            Button("Forget", role: .destructive) { bt.forget(role); dismiss() }
                        }
                    }
                }
                Section {
                    ForEach(candidates) { d in
                        Button {
                            bt.connect(d, as: role)
                            bt.stopScanning()
                            dismiss()
                        } label: {
                            HStack {
                                Text(d.name)
                                Spacer()
                                Image(systemName: rssiSymbol(d.rssi)).foregroundStyle(.secondary)
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                    if candidates.isEmpty {
                        HStack { ProgressView(); Text("Looking for devices…").foregroundStyle(.secondary) }
                    }
                } header: {
                    Text("Nearby")
                } footer: {
                    Text("Wake the device (spin the pedals, wear the band) so it advertises.")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(roleTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .onAppear { bt.startScanning() }
            .onDisappear { bt.stopScanning() }
        }
    }

    private var roleTitle: LocalizedStringKey {
        switch role {
        case .trainer: return "Smart trainer"
        case .heartRate: return "Heart rate"
        case .powerMeter: return "Power meter"
        }
    }

    private func rssiSymbol(_ rssi: Int) -> String {
        switch rssi {
        case (-60)...: return "wifi"
        case (-75)...: return "wifi.exclamationmark"
        default: return "wifi.slash"
        }
    }
}

#Preview {
    PreRideFlow(workout: PreviewData.state.today!.workout, plannedSession: nil).environment(PreviewData.model())
}
