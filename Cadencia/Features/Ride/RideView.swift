import SwiftUI
import Charts
import CadenciaCore

/// Live ride as a game HUD (concept B): numbers strip, workout timeline with playhead, the target with a
/// tolerance band and the live marker inside it, the block countdown, what's next, the last two minutes
/// of power, and the controls. The coach's line appears as a subtitle over the chart and fades out.
struct RideView: View {
    let session: RideSession
    let onFinish: (RideRecording) -> Void

    @State private var confirmEnd = false
    @State private var showProfile = false
    @State private var captionShown = false
    @State private var captionHide: Task<Void, Never>?

    private var engine: RideEngine { session.engine }
    private var live: BluetoothManager.Live { session.live }

    var body: some View {
        VStack(spacing: 0) {
            hud
            timeline.padding(.top, 12)
            Spacer(minLength: 0)
            targetHero
            Spacer(minLength: 0)
            Divider().padding(.vertical, 6)
            blockCountdown
            upNext.padding(.top, 8)
            sparkline.padding(.top, 8)
            controls.padding(.top, 12)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
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
        .onChange(of: session.commentator?.caption) { _, caption in
            guard caption != nil else { return }
            captionHide?.cancel()
            withAnimation(.spring(duration: 0.4)) { captionShown = true }
            captionHide = Task {
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.6)) { captionShown = false }
            }
        }
        .sheet(isPresented: $showProfile) {
            NavigationStack {
                WorkoutProfileView(workout: engine.workout, ftp: engine.ftp, ceilingWatts: engine.ceilingWatts)
                    .frame(height: 220)
                    .padding()
                    .navigationTitle(engine.workout.name)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showProfile = false } } }
            }
            .presentationDetents([.medium])
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
            hudCell("HR", live.heartRate.map { "\($0)" } ?? "–", unit: "bpm", tint: live.heartRate == nil ? .pink : .white)
            hudDivider
            hudCell("Cadence", live.cadence.map { "\($0)" } ?? "–", unit: "rpm", tint: .white)
            hudDivider
            hudCell("Time", Format.clock(engine.elapsed), unit: nil, tint: .white)
            hudDivider
            hudCell("Left", Format.clock(engine.remainingTotal), unit: nil, tint: .white)
        }
        .padding(.vertical, 10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
    }

    private var hudDivider: some View { Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1, height: 40) }

    private func hudCell(_ title: LocalizedStringKey, _ value: String, unit: String?, tint: Color) -> some View {
        VStack(spacing: 3) {
            Text(title).font(.caption2.weight(.medium)).textCase(.uppercase).foregroundStyle(.secondary).tracking(0.6)
            Text(value)
                .font(.system(size: 26, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(tint)
                .contentTransition(.numericText())
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(unit ?? " ").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Timeline

    private struct Cell: Identifiable {
        let id: Int
        let step: Int
        let start: TimeInterval
        let duration: TimeInterval
        let intensity: Double
    }

    /// The workout cut into ~1-minute cells (20 s inside ramps so the slope shows), coloured by zone.
    private var cells: [Cell] {
        var out: [Cell] = []
        var offset: TimeInterval = 0
        for (i, step) in engine.workout.steps.enumerated() {
            let size: TimeInterval = step.isRamp ? 20 : 60
            let n = max(1, Int((step.duration / size).rounded(.up)))
            let d = step.duration / Double(n)
            for k in 0..<n {
                out.append(Cell(id: out.count, step: i, start: offset + Double(k) * d, duration: d, intensity: step.intensity(at: (Double(k) + 0.5) * d)))
            }
            offset += step.duration
        }
        return out
    }

    private var timeline: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                let total = max(engine.workout.totalDuration, 1)
                let cells = cells
                let peak = max(cells.map(\.intensity).max() ?? 1, 0.4)
                let gap: CGFloat = 1.5
                ZStack(alignment: .bottomLeading) {
                    HStack(alignment: .bottom, spacing: gap) {
                        ForEach(cells) { cell in
                            let past = cell.start + cell.duration <= engine.elapsed
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(past ? Color.white.opacity(0.28) : Zone.color(for: cell.intensity).opacity(cell.step == engine.currentStepIndex ? 1 : 0.75))
                                .frame(width: max(geo.size.width * CGFloat(cell.duration / total) - gap, 1.5),
                                       height: max(geo.size.height * CGFloat(cell.intensity / peak), 4))
                        }
                    }
                    .frame(width: geo.size.width, alignment: .leading)
                    Capsule()
                        .fill(.white)
                        .frame(width: 3, height: geo.size.height + 6)
                        .shadow(color: .white.opacity(0.9), radius: 4)
                        .offset(x: geo.size.width * CGFloat(engine.progress) - 1.5, y: 3)
                }
            }
            .frame(height: 26)
            HStack {
                Text("Block \(blockNumber) of \(engine.workout.steps.count)")
                Spacer()
                Text("\(Format.clock(engine.remainingTotal)) left")
            }
            .font(.subheadline).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture { showProfile = true }
    }

    private var blockNumber: Int {
        min((engine.currentStepIndex ?? engine.workout.steps.count - 1) + 1, engine.workout.steps.count)
    }

    // MARK: Target

    private var targetHero: some View {
        VStack(spacing: 0) {
            Text("Target").font(.footnote.weight(.medium)).textCase(.uppercase).foregroundStyle(.secondary).tracking(1)
            Text(engine.targetWatts.map { "\($0)" } ?? "–")
                .font(.system(size: 92, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
                .shadow(color: .white.opacity(0.25), radius: 12)
                .contentTransition(.numericText())
                .padding(.vertical, -10)
            Text("W").font(.title3.weight(.semibold)).foregroundStyle(.secondary)
            toleranceBand.padding(.top, 10)
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
            .padding(.top, 6)
        }
        .animation(.default, value: engine.targetWatts)
    }

    private var tolerance: Double { RideCommentary.zoneTolerance }

    /// The band covers ±25 % of target; the green zone is ±10 %. The live marker is clamped to the band
    /// so a wildly off number is still shown pinned at the edge. Under the band: the zone edges and the live value.
    private var toleranceBand: some View {
        GeometryReader { geo in
            // Precompute values as locals; avoid declaring functions inside ViewBuilder
            let target = Double(engine.targetWatts ?? 0)
            let lo = target * 0.75
            let hi = target * 1.25
            let zoneLo = target * (1 - tolerance)
            let zoneHi = target * (1 + tolerance)
            let w = geo.size.width
            let bandH: CGFloat = 36
            // Inline mapping from watts to x position
            let xLo = hi > lo ? w * CGFloat((min(max(zoneLo, lo), hi) - lo) / (hi - lo)) : w / 2
            let xHi = hi > lo ? w * CGFloat((min(max(zoneHi, lo), hi) - lo) / (hi - lo)) : w / 2
            let liveWatts = live.watts
            let xLive: CGFloat = {
                guard let watts = liveWatts else { return hi > lo ? w * 0.5 : w / 2 }
                if hi > lo {
                    let clamped = min(max(Double(watts), lo), hi)
                    return w * CGFloat((clamped - lo) / (hi - lo))
                } else {
                    return w / 2
                }
            }()

            ZStack(alignment: .topLeading) {
                Capsule().fill(Color(.secondarySystemBackground)).frame(height: bandH)
                RoundedRectangle(cornerRadius: 4)
                    .fill(LinearGradient(colors: [.green.opacity(0.95), .green.opacity(0.7)], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(xHi - xLo, 6), height: bandH)
                    .offset(x: xLo)
                HStack {
                    Text("< \(Int(zoneLo.rounded()))").padding(.leading, 14)
                    Spacer()
                    Text("> \(Int(zoneHi.rounded()))").padding(.trailing, 14)
                }
                .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                .frame(height: bandH)
                if let watts = liveWatts {
                    Capsule().fill(.white)
                        .frame(width: 5, height: bandH + 10)
                        .shadow(color: .white.opacity(0.8), radius: 4)
                        .offset(x: xLive - 2.5, y: -5)
                }
                // Scale under the band: zone edges in gray, the live value in white under its marker.
                ZStack(alignment: .topLeading) {
                    Text("\(Int(zoneLo.rounded()))").foregroundStyle(.secondary)
                        .frame(width: 60).offset(x: xLo - 30)
                    Text("\(Int(zoneHi.rounded()))").foregroundStyle(.secondary)
                        .frame(width: 60).offset(x: xHi - 30)
                    if let watts = liveWatts {
                        Text("\(watts)").foregroundStyle(.white).fontWeight(.semibold)
                            .padding(.horizontal, 4).background(Color.black)
                            .frame(width: 60).offset(x: xLive - 30)
                    }
                }
                .font(.subheadline.monospacedDigit())
                .offset(y: bandH + 6)
            }
        }
        .frame(height: 36 + 6 + 18)
        .animation(.easeOut(duration: 0.4), value: live.watts)
    }

    private var zoneText: LocalizedStringKey {
        guard let w = live.watts, let t = engine.targetWatts, t > 0 else { return "No power" }
        if let c = engine.ceilingWatts, w > c + 10 { return "Over the ceiling" }
        let ratio = Double(w) / Double(t)
        if ratio > 1 + tolerance { return "Too hard" }
        if ratio < 1 - tolerance { return "Too easy" }
        return "In zone"
    }

    /// Share of this block's seconds so far spent inside the zone.
    private var inZonePercent: Int? {
        guard let i = engine.currentStepIndex, engine.elapsedInStep >= 10 else { return nil }
        return RideCommentary.BlockStats.compute(index: i, workout: engine.workout, ftp: engine.ftp, samples: engine.recording.samples, upTo: engine.elapsed).inZonePercent
    }

    /// Green inside the zone, orange above, blue below. Red above the ceiling.
    private var powerTint: Color {
        guard let w = live.watts, let t = engine.targetWatts, t > 0 else { return .white }
        if let c = engine.ceilingWatts, w > c + 10 { return .red }
        let ratio = Double(w) / Double(t)
        if ratio > 1 + tolerance { return .orange }
        if ratio < 1 - tolerance { return .blue }
        return .green
    }

    // MARK: Block and next

    private var blockCountdown: some View {
        VStack(spacing: 2) {
            Text(Format.clock(engine.remainingInStep))
                .font(.system(size: 60, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
                .contentTransition(.numericText())
            if let step = engine.currentStep {
                Text("\(step.name) · \(stepWatts(step)) · \(Format.minutes(step.duration))")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
        }
    }

    private var upNext: some View {
        Button { showProfile = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "chart.bar.fill").foregroundStyle(Color.accentColor).font(.title3)
                Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1, height: 24)
                if let i = engine.currentStepIndex, i + 1 < engine.workout.steps.count {
                    let next = engine.workout.steps[i + 1]
                    Text("Up next:").foregroundStyle(.secondary)
                    Text(next.name).fontWeight(.semibold).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.7).layoutPriority(1)
                    Text("· \(stepWatts(next)) · \(Format.clock(next.duration))").foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                } else {
                    Text("Last block").foregroundStyle(.secondary)
                    Text("Finish strong").fontWeight(.semibold).foregroundStyle(.white)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            }
            .font(.subheadline)
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
    }

    private func stepWatts(_ step: WorkoutStep) -> String {
        func watts(_ i: Double) -> Int {
            var v = i * engine.intensityScale
            if let c = engine.workout.intensityCeiling { v = min(v, c) }
            return Int((v * Double(engine.ftp)).rounded())
        }
        return step.isRamp ? "\(watts(step.startIntensity))→\(watts(step.endIntensity)) W" : "\(watts(step.startIntensity)) W"
    }

    // MARK: Sparkline

    private struct Point: Identifiable {
        let id: Int        // seconds ago, 0…120
        let watts: Int
        let target: Int?
    }

    /// The last two minutes of 1 Hz samples, x = seconds ago (120 → 0).
    private var recent: [Point] {
        let samples = engine.recording.samples.suffix(120)
        let n = samples.count
        return samples.enumerated().compactMap { k, s in
            s.watts.map { Point(id: n - 1 - k, watts: $0, target: s.targetWatts) }
        }
    }

    private var sparkline: some View {
        VStack(spacing: 4) {
            HStack {
                Text("Power (last 2 min)").font(.caption.weight(.medium)).textCase(.uppercase).foregroundStyle(.secondary).tracking(0.6)
                Spacer()
                Text(live.watts.map { "\($0) W" } ?? "–").font(.callout.weight(.semibold).monospacedDigit()).foregroundStyle(powerTint)
            }
            ZStack(alignment: .bottom) {
                powerChart
                if captionShown, let caption = session.commentator?.caption, session.commentator?.captionsEnabled == true {
                    coachSubtitle(caption)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
    }

    private var yMax: Int {
        let peak = engine.workout.steps.map { max($0.startIntensity, $0.endIntensity) }.max() ?? 1
        let planned = Double(engine.ftp) * peak * engine.intensityScale
        let seen = Double(recent.map(\.watts).max() ?? 0)
        return Int((max(planned, seen, 100) * 1.15 / 20).rounded(.up)) * 20
    }

    private var powerChart: some View {
        let points = recent
        return Chart {
            ForEach(points) { p in
                AreaMark(x: .value("Ago", -p.id), y: .value("W", p.watts))
                    .foregroundStyle(LinearGradient(colors: [.green.opacity(0.45), .green.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Ago", -p.id), y: .value("W", p.watts))
                    .foregroundStyle(.green)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .interpolationMethod(.monotone)
            }
            if let target = engine.targetWatts {
                RuleMark(y: .value("Target", target))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .foregroundStyle(.white.opacity(0.35))
            }
            if let last = points.last {
                PointMark(x: .value("Ago", -last.id), y: .value("W", last.watts))
                    .foregroundStyle(.green)
                    .symbolSize(50)
            }
        }
        .chartXScale(domain: -120...0)
        .chartYScale(domain: 0...yMax)
        .chartXAxis {
            AxisMarks(values: [-120, 0]) { value in
                AxisValueLabel {
                    if let v = value.as(Int.self) { Text(Format.clock(TimeInterval(-v))).font(.caption2).foregroundStyle(.secondary) }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3])).foregroundStyle(.white.opacity(0.15))
                AxisValueLabel().font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(height: 80)
    }

    // MARK: Coach

    /// Game-style subtitle: the coach's line over the chart, with its mood as icon and tint.
    private func coachSubtitle(_ caption: RideCommentator.Caption) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: moodSymbol(caption.line.mood))
                .foregroundStyle(moodTint(caption.line.mood))
                .font(.title3)
            Text(caption.line.caption)
                .font(.callout.weight(.medium))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(moodTint(caption.line.mood).opacity(0.5), lineWidth: 1))
        .padding(.bottom, 18)
        .onTapGesture { withAnimation { captionShown = false } }
    }

    private func coachMenu(_ commentator: RideCommentator) -> some View {
        Menu {
            Toggle(isOn: Binding(get: { commentator.voiceEnabled }, set: { commentator.voiceEnabled = $0 })) { Label("Voice", systemImage: "speaker.wave.2") }
            Toggle(isOn: Binding(get: { commentator.captionsEnabled }, set: { commentator.captionsEnabled = $0 })) { Label("Captions", systemImage: "captions.bubble") }
            if let caption = commentator.caption {
                Divider()
                Button { withAnimation { captionShown = true } } label: { Label(caption.line.caption, systemImage: "quote.bubble") }
            }
        } label: {
            Image(systemName: commentator.thinking ? "waveform" : (commentator.voiceEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill"))
                .symbolEffect(.variableColor.iterative, isActive: commentator.thinking)
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

    /// Two rows of equal pills like the concept, but each says what it does: Easier · intensity · Harder,
    /// then Pause/Resume and End ride (asks first).
    private var controls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Button { session.adjustIntensity(by: -0.05) } label: {
                    Label("Easier", systemImage: "minus").frame(maxWidth: .infinity)
                }
                .disabled(engine.intensityScale <= 0.8)
                VStack(spacing: 0) {
                    Text(String(format: "%.0f %%", engine.intensityScale * 100))
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(engine.intensityScale == 1 ? Color.white : .orange)
                        .contentTransition(.numericText())
                    Text("Intensity").font(.caption2).foregroundStyle(.secondary)
                }
                .frame(width: 76)
                Button { session.adjustIntensity(by: 0.05) } label: {
                    Label("Harder", systemImage: "plus").frame(maxWidth: .infinity)
                }
                .disabled(engine.intensityScale >= 1.2)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .animation(.default, value: engine.intensityScale)

            HStack(spacing: 12) {
                if engine.state == .riding {
                    Button { session.pause() } label: { Label("Pause", systemImage: "pause.fill").frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered)
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
