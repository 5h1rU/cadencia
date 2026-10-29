import SwiftUI
import CadenciaCore

/// Live ride: target and ceiling, what the sensors say, where you are in the session.
struct RideView: View {
    let session: RideSession
    let onFinish: (RideRecording) -> Void

    @State private var confirmEnd = false

    private var engine: RideEngine { session.engine }
    private var live: BluetoothManager.Live { session.live }

    var body: some View {
        VStack(spacing: 24) {
            header
            targetBlock
            Divider()
            sensors
            Spacer()
            controls
        }
        .padding()
        .navigationTitle(engine.workout.name)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
        .onAppear { if engine.state == .ready { session.start() } }
        .onChange(of: engine.state) { _, state in
            if state == .finished { onFinish(session.finish()) }
        }
        .alert("Trainer disconnected", isPresented: Binding(get: { session.trainerLostAlert }, set: { _ in session.acknowledgeTrainerLoss() })) {
            Button("Wait for it") {}
            Button("End ride", role: .destructive) { onFinish(session.finish()) }
        } message: {
            Text("The ride is paused and nothing is lost. The app keeps trying to reconnect; resume when the trainer is back.")
        }
        .confirmationDialog("End this ride?", isPresented: $confirmEnd, titleVisibility: .visible) {
            Button("End and save", role: .destructive) { onFinish(session.finish()) }
        } message: {
            Text("What you rode so far is kept and sent to Intervals.")
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            ProgressView(value: engine.progress)
            HStack {
                VStack(alignment: .leading) {
                    Text(engine.currentStep?.name ?? "Done").font(.headline)
                    Text("Block \(min((engine.currentStepIndex ?? engine.workout.steps.count - 1) + 1, engine.workout.steps.count)) of \(engine.workout.steps.count)")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing) {
                    Text(Format.clock(engine.remainingInStep)).font(.title2.monospacedDigit().weight(.semibold))
                    Text("\(Format.clock(engine.remainingTotal)) left").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var targetBlock: some View {
        VStack(spacing: 4) {
            Text("Target").font(.caption).foregroundStyle(.secondary).textCase(.uppercase)
            Text(engine.targetWatts.map { "\($0)" } ?? "–")
                .font(.system(size: 88, weight: .bold, design: .rounded).monospacedDigit())
                .contentTransition(.numericText())
            HStack(spacing: 12) {
                if let ceiling = engine.ceilingWatts {
                    Label("Ceiling \(ceiling) W", systemImage: "arrow.up.to.line").font(.footnote).foregroundStyle(.secondary)
                }
                if engine.intensityScale != 1 {
                    Text(String(format: "%+.0f %%", (engine.intensityScale - 1) * 100)).font(.footnote).foregroundStyle(.orange)
                }
                if !session.ergEnabled {
                    Text("Manual").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical)
        .background(powerTint.opacity(0.12), in: RoundedRectangle(cornerRadius: 20))
        .animation(.default, value: engine.targetWatts)
    }

    private var sensors: some View {
        HStack {
            sensor("Power", live.watts.map { "\($0)" } ?? "–", unit: "W", tint: powerTint)
            sensor("Heart rate", live.heartRate.map { "\($0)" } ?? "–", unit: "bpm", tint: .pink)
            sensor("Cadence", live.cadence.map { "\($0)" } ?? "–", unit: "rpm", tint: .primary)
        }
    }

    private func sensor(_ title: LocalizedStringKey, _ value: String, unit: String, tint: Color) -> some View {
        VStack(spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 36, weight: .semibold, design: .rounded).monospacedDigit()).foregroundStyle(tint)
            Text(unit).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    /// Green inside ±5 % of target, orange above, blue below. Red above the ceiling.
    private var powerTint: Color {
        guard let w = live.watts, let t = engine.targetWatts, t > 0 else { return .primary }
        if let c = engine.ceilingWatts, w > c + 10 { return .red }
        let ratio = Double(w) / Double(t)
        if ratio > 1.05 { return .orange }
        if ratio < 0.95 { return .blue }
        return .green
    }

    private var controls: some View {
        VStack(spacing: 16) {
            HStack(spacing: 16) {
                Button { session.adjustIntensity(by: -0.05) } label: { Image(systemName: "minus").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered)
                    .disabled(engine.intensityScale <= 0.8)
                Button { session.adjustIntensity(by: 0.05) } label: { Image(systemName: "plus").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered)
                    .disabled(engine.intensityScale >= 1.2)
            }
            .controlSize(.large)
            HStack(spacing: 16) {
                if engine.state == .riding {
                    Button { session.pause() } label: { Label("Pause", systemImage: "pause.fill").frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered)
                } else {
                    Button { session.resume() } label: { Label("Resume", systemImage: "play.fill").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent)
                }
                Button(role: .destructive) { confirmEnd = true } label: { Label("End", systemImage: "stop.fill").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered)
            }
            .controlSize(.large)
        }
    }
}
