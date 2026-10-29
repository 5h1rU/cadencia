import SwiftUI
import CadenciaCore

/// Live ride, laid out like a game HUD: the numbers strip on top, the workout timeline, the target with
/// a tolerance band and the live marker inside it, the block countdown, what comes next, and the coach's
/// line. Built to be read in a glance from the saddle.
struct RideView: View {
    let session: RideSession
    let onFinish: (RideRecording) -> Void

    @State private var confirmEnd = false

    private var engine: RideEngine { session.engine }
    private var live: BluetoothManager.Live { session.live }

    var body: some View {
        VStack(spacing: 14) {
            hud
            timeline
            Spacer(minLength: 0)
            targetHero
            blockCountdown
            upNext
            coachLine
            Spacer(minLength: 0)
            controls
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
        .navigationTitle(engine.workout.name)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
        .toolbar {
            if let commentator = session.commentator {
                ToolbarItem(placement: .topBarTrailing) { coachMenu(commentator) }
            }
        }
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

    // MARK: HUD strip

    private var hud: some View {
        HStack(spacing: 0) {
            hudCell("Power", live.watts.map { "\($0)" } ?? "–", unit: "W", tint: powerTint)
            hudDivider
            hudCell("HR", live.heartRate.map { "\($0)" } ?? "–", unit: "bpm", tint: live.heartRate == nil ? .pink : .primary)
            hudDivider
            hudCell("Cadence", live.cadence.map { "\($0)" } ?? "–", unit: "rpm", tint: .primary)
            hudDivider
            hudCell("Time", Format.clock(engine.elapsed), unit: nil, tint: .primary)
            hudDivider
            hudCell("Left", Format.clock(engine.remainingTotal), unit: nil, tint: .primary)
        }
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var hudDivider: some View { Divider().frame(height: 36) }

    private func hudCell(_ title: LocalizedStringKey, _ value: String, unit: String?, tint: Color) -> some View {
        VStack(spacing: 2) {
            Text(title).font(.caption2).textCase(.uppercase).foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 26, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(tint)
                .contentTransition(.numericText())
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(unit ?? " ").font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Timeline

    /// The whole workout as one strip: each block's width is its share of the time, its height the
    /// intensity, past blocks dimmed, with a playhead at the current second.
    private var timeline: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                let total = max(engine.workout.totalDuration, 1)
                let peak = max(engine.workout.steps.map { max($0.startIntensity, $0.endIntensity) }.max() ?? 1, 0.5)
                ZStack(alignment: .bottomLeading) {
                    HStack(alignment: .bottom, spacing: 1) {
                        ForEach(Array(engine.workout.steps.enumerated()), id: \.element.id) { i, step in
                            let height = max(geo.size.height * CGFloat(step.intensity(at: step.duration / 2) / peak), 3)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(i < (engine.currentStepIndex ?? engine.workout.steps.count) ? Color.secondary.opacity(0.35) : (i == engine.currentStepIndex ? Color.accentColor : Color.accentColor.opacity(0.55)))
                                .frame(width: max(geo.size.width * CGFloat(step.duration / total) - 1, 2), height: height)
                        }
                    }
                    Rectangle()
                        .fill(.white)
                        .frame(width: 2, height: geo.size.height)
                        .shadow(color: .white.opacity(0.8), radius: 3)
                        .offset(x: geo.size.width * CGFloat(engine.progress))
                }
            }
            .frame(height: 22)
            HStack {
                Text("Block \(blockNumber) of \(engine.workout.steps.count)")
                Spacer()
                Text(Format.percent(engine.progress))
            }
            .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var blockNumber: Int {
        min((engine.currentStepIndex ?? engine.workout.steps.count - 1) + 1, engine.workout.steps.count)
    }

    // MARK: Target

    private var targetHero: some View {
        VStack(spacing: 8) {
            Text("Target").font(.caption).textCase(.uppercase).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(engine.targetWatts.map { "\($0)" } ?? "–")
                    .font(.system(size: 96, weight: .bold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText())
                Text("W").font(.title2.weight(.semibold)).foregroundStyle(.secondary)
            }
            toleranceBand
            HStack(spacing: 6) {
                Text(zoneText).foregroundStyle(powerTint).fontWeight(.semibold)
                if let inZone = inZonePercent {
                    Text("·").foregroundStyle(.secondary)
                    Text("\(inZone) % of block").foregroundStyle(.secondary)
                }
                if let ceiling = engine.ceilingWatts, let t = engine.targetWatts, t >= ceiling {
                    Text("·").foregroundStyle(.secondary)
                    Label("Ceiling", systemImage: "arrow.up.to.line").foregroundStyle(.secondary)
                }
                if !session.ergEnabled {
                    Text("·").foregroundStyle(.secondary)
                    Text("Manual").foregroundStyle(.secondary)
                }
            }
            .font(.subheadline)
        }
        .animation(.default, value: engine.targetWatts)
    }

    /// ±5 % of the target is "in zone". The band spans ±25 % so a marker outside the green is still on screen.
    private var toleranceBand: some View {
        GeometryReader { geo in
            let target = Double(engine.targetWatts ?? 0)
            let lo = target * 0.75, hi = target * 1.25
            func x(_ w: Double) -> CGFloat { hi > lo ? geo.size.width * CGFloat((min(max(w, lo), hi) - lo) / (hi - lo)) : 0 }
            ZStack(alignment: .leading) {
                Capsule().fill(Color(.tertiarySystemFill))
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.green.opacity(0.75))
                    .frame(width: max(x(target * 1.05) - x(target * 0.95), 4))
                    .offset(x: x(target * 0.95))
                if let w = live.watts {
                    Capsule().fill(.white)
                        .frame(width: 4, height: geo.size.height + 8)
                        .shadow(color: .white.opacity(0.6), radius: 3)
                        .offset(x: x(Double(w)) - 2)
                }
                HStack {
                    Text("\(Int(target * 0.95))").padding(.leading, 8)
                    Spacer()
                    Text("\(Int(target * 1.05))").padding(.trailing, 8)
                }
                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .frame(height: 24)
        .padding(.horizontal, 8)
        .animation(.easeOut(duration: 0.4), value: live.watts)
    }

    private var zoneText: LocalizedStringKey {
        guard let w = live.watts, let t = engine.targetWatts, t > 0 else { return "No power" }
        if let c = engine.ceilingWatts, w > c + 10 { return "Over the ceiling" }
        let ratio = Double(w) / Double(t)
        if ratio > 1.05 { return "Too hard" }
        if ratio < 0.95 { return "Too easy" }
        return "In zone"
    }

    /// Share of this block's seconds so far spent within ±5 % of target.
    private var inZonePercent: Int? {
        guard let i = engine.currentStepIndex, engine.elapsedInStep >= 10 else { return nil }
        return RideCommentary.BlockStats.compute(index: i, workout: engine.workout, ftp: engine.ftp, samples: engine.recording.samples, upTo: engine.elapsed).inZonePercent
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

    // MARK: Block and next

    private var blockCountdown: some View {
        VStack(spacing: 2) {
            Text(Format.clock(engine.remainingInStep))
                .font(.system(size: 56, weight: .semibold, design: .rounded).monospacedDigit())
                .contentTransition(.numericText())
            if let step = engine.currentStep {
                Text("\(step.name) · \(stepWatts(step)) · \(Format.minutes(step.duration))")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
        }
    }

    @ViewBuilder private var upNext: some View {
        if let i = engine.currentStepIndex, i + 1 < engine.workout.steps.count {
            let next = engine.workout.steps[i + 1]
            HStack(spacing: 12) {
                Image(systemName: "chart.bar.fill").foregroundStyle(Color.accentColor)
                Text("Up next").foregroundStyle(.secondary)
                Text(next.name).fontWeight(.semibold).lineLimit(1)
                Spacer()
                Text("\(stepWatts(next)) · \(Format.minutes(next.duration))").foregroundStyle(.secondary).monospacedDigit()
            }
            .font(.subheadline)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        } else {
            HStack(spacing: 12) {
                Image(systemName: "flag.checkered")
                Text("Last block").foregroundStyle(.secondary)
                Spacer()
            }
            .font(.subheadline)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private func stepWatts(_ step: WorkoutStep) -> String {
        func watts(_ i: Double) -> Int {
            var v = i * engine.intensityScale
            if let c = engine.workout.intensityCeiling { v = min(v, c) }
            return Int((v * Double(engine.ftp)).rounded())
        }
        return step.isRamp ? "\(watts(step.startIntensity))→\(watts(step.endIntensity)) W" : "\(watts(step.startIntensity)) W"
    }

    // MARK: Coach

    @ViewBuilder private var coachLine: some View {
        if let commentator = session.commentator, commentator.captionsEnabled {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: commentator.caption.map { moodSymbol($0.line.mood) } ?? "waveform")
                    .foregroundStyle(commentator.caption.map { moodTint($0.line.mood) } ?? .secondary)
                    .font(.title3)
                    .frame(width: 24)
                    .symbolEffect(.variableColor.iterative, isActive: commentator.thinking)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Coach").font(.caption).foregroundStyle(.secondary)
                    if let caption = commentator.caption {
                        Text(caption.line.caption).font(.callout).fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(commentator.thinking ? "Reading your numbers…" : "Listening to your numbers.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .animation(.default, value: commentator.caption)
        }
    }

    private func coachMenu(_ commentator: RideCommentator) -> some View {
        Menu {
            Toggle(isOn: Binding(get: { commentator.voiceEnabled }, set: { commentator.voiceEnabled = $0 })) { Label("Voice", systemImage: "speaker.wave.2") }
            Toggle(isOn: Binding(get: { commentator.captionsEnabled }, set: { commentator.captionsEnabled = $0 })) { Label("Captions", systemImage: "captions.bubble") }
        } label: {
            Image(systemName: commentator.voiceEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
        }
    }

    private func moodSymbol(_ mood: RideCommentary.Line.Mood) -> String {
        switch mood {
        case .praise: return "hands.clap.fill"
        case .push: return "flame.fill"
        case .caution: return "exclamationmark.triangle.fill"
        case .calm: return "leaf.fill"
        case .steady: return "quote.bubble.fill"
        }
    }

    private func moodTint(_ mood: RideCommentary.Line.Mood) -> Color {
        switch mood {
        case .praise: return .green
        case .push: return .orange
        case .caution: return .red
        case .calm: return .teal
        case .steady: return .accentColor
        }
    }

    // MARK: Controls

    /// Intensity is one labelled control, not two bare glyphs: "Easier · 100 % · Harder". Pause/Resume is
    /// the prominent action; End is red and asks for confirmation.
    private var controls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 0) {
                Button { session.adjustIntensity(by: -0.05) } label: {
                    Label("Easier", systemImage: "minus.circle.fill").frame(maxWidth: .infinity)
                }
                .disabled(engine.intensityScale <= 0.8)
                VStack(spacing: 0) {
                    Text(String(format: "%.0f %%", engine.intensityScale * 100))
                        .font(.title3.weight(.semibold).monospacedDigit())
                        .foregroundStyle(engine.intensityScale == 1 ? Color.primary : .orange)
                        .contentTransition(.numericText())
                    Text("Intensity").font(.caption2).foregroundStyle(.secondary)
                }
                .frame(width: 92)
                Button { session.adjustIntensity(by: 0.05) } label: {
                    Label("Harder", systemImage: "plus.circle.fill").frame(maxWidth: .infinity)
                }
                .disabled(engine.intensityScale >= 1.2)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .animation(.default, value: engine.intensityScale)

            HStack(spacing: 12) {
                if engine.state == .riding {
                    Button { session.pause() } label: { Label("Pause", systemImage: "pause.fill").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button { session.resume() } label: { Label("Resume", systemImage: "play.fill").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                }
                Button(role: .destructive) { confirmEnd = true } label: { Label("End ride", systemImage: "stop.fill").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered)
            }
            .controlSize(.large)
        }
    }
}
