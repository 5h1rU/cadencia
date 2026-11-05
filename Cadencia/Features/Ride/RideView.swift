import SwiftUI
import Charts
import CadenciaCore

/// Live ride as a game HUD (concept B): numbers strip, workout timeline with playhead, the target with a
/// tolerance band and the live marker inside it, the block countdown, what's next, the last two minutes
/// of power, and the controls. The coach's caption opens into a full, scrollable message.
struct RideView: View {
    let session: RideSession
    let onFinish: (RideRecording) -> Void

    @State private var confirmEnd = false
    @State private var showProfile = false
    @State private var profileDetent: PresentationDetent = .large
    @State private var coachMessage: CoachMessage?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .title2) private var hudValueSize = 26.0
    @ScaledMetric(relativeTo: .subheadline) private var bandLabelHeight = 18.0
    @ScaledMetric(relativeTo: .title2) private var coachIconWidth = 24.0

    private struct CoachMessage: Identifiable {
        let id = UUID()
        let text: String
    }

    private var engine: RideEngine { session.engine }
    private var live: BluetoothManager.Live { session.live }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    hud
                    WorkoutTimelineStrip(session: session)
                        .contentShape(Rectangle())
                        .onTapGesture { showProfile = true }
                        .padding(.top, 12)
                    Spacer(minLength: 12)
                    targetHero
                    Spacer(minLength: 12)
                    Divider().padding(.vertical, 6)
                    blockCountdown
                    upNext.padding(.top, 8)
                    sparkline.padding(.top, 8)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .frame(minHeight: geometry.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(Color.black.ignoresSafeArea())
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 10) {
                coachLine
                controls
            }
            .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 4)
            .background(Color.black)
        }
        .preferredColorScheme(.dark)
        .navigationTitle(engine.workout.name)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { rideMenu }
        }
        .onAppear {
            if engine.state == .ready { session.start() }
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--cadencia-preview-workout-profile") { showProfile = true }
            if ProcessInfo.processInfo.arguments.contains("--cadencia-preview-coach-message"),
               let caption = session.commentator?.caption {
                coachMessage = CoachMessage(text: caption.line.caption)
            }
            #endif
        }
        .onChange(of: engine.state) { _, state in
            if state == .finished { onFinish(session.finish()) }
        }
        .sheet(isPresented: $showProfile) {
            NavigationStack {
                List {
                    WorkoutProfileView(workout: engine.workout, ftp: engine.ftp, ceilingWatts: engine.ceilingWatts)
                        .frame(height: 220)
                    Section("Workout blocks") {
                        ForEach(Array(engine.workout.steps.enumerated()), id: \.offset) { _, step in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(step.name).font(.headline).fixedSize(horizontal: false, vertical: true)
                                Text("\(stepWatts(step)) · \(Format.clock(step.duration))")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                .navigationTitle(engine.workout.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showProfile = false } } }
            }
            .presentationDetents([.medium, .large], selection: $profileDetent)
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $coachMessage) { message in
            NavigationStack {
                ScrollView {
                    Text(message.text)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding()
                }
                .navigationTitle("Coach message")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { coachMessage = nil }
                    }
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .alert("Trainer disconnected", isPresented: Binding(get: { session.trainerLostAlert }, set: { _ in session.acknowledgeTrainerLoss() })) {
            Button("Wait for it") {}
            Button("End ride", role: .destructive) { onFinish(session.finish()) }
        } message: {
            Text("The ride is paused and nothing is lost. The app keeps trying to reconnect; resume when the trainer is back.")
        }
        .alert("Pause workout?", isPresented: Binding(get: { engine.shouldSuggestPause }, set: { if !$0 { session.keepRiding() } })) {
            Button("Pause") { session.pause() }
            Button("Keep riding", role: .cancel) { session.keepRiding() }
        } message: {
            Text("You haven't pedaled for 5 seconds. Pause the workout timer until you're ready to resume?")
        }
        .confirmationDialog("End this ride?", isPresented: $confirmEnd, titleVisibility: .visible) {
            Button("End and save", role: .destructive) { onFinish(session.finish()) }
        } message: {
            Text("What you rode so far is kept and sent to Intervals.")
        }
    }

    // MARK: HUD strip

    private var usesTimerRow: Bool {
        engine.workout.totalDuration >= 3600 || dynamicTypeSize.isAccessibilitySize
    }

    private var hud: some View {
        VStack(spacing: 8) {
            if usesTimerRow {
                HStack(spacing: 0) {
                    sensorCells
                }
                Divider().overlay(Color.white.opacity(0.12))
                HStack(spacing: 0) {
                    timerCells
                }
            } else {
                HStack(spacing: 0) {
                    sensorCells
                    hudDivider
                    timerCells
                }
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 6)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
    }

    @ViewBuilder private var sensorCells: some View {
        hudCell("Power", live.watts.map { "\($0)" } ?? "–", unit: "W", tint: powerTint)
        hudDivider
        hudCell("HR", live.heartRate.map { "\($0)" } ?? "–", unit: "bpm", tint: live.heartRate == nil ? .pink : .white)
        hudDivider
        hudCell("Cadence", live.cadence.map { "\($0)" } ?? "–", unit: "rpm", tint: .white)
    }

    @ViewBuilder private var timerCells: some View {
        hudCell("Time", Format.clock(engine.elapsed), unit: nil, tint: .white)
        hudDivider
        hudCell("Left", Format.countdown(engine.remainingTotal), unit: nil, tint: .white)
    }

    private var hudDivider: some View { Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1, height: 40) }

    private func hudCell(_ title: LocalizedStringKey, _ value: String, unit: String?, tint: Color) -> some View {
        VStack(spacing: 3) {
            Text(title).font(.caption2.weight(.medium)).textCase(.uppercase).foregroundStyle(.secondary).tracking(0.6)
                .lineLimit(1).minimumScaleFactor(0.4)
            Text(value)
                .font(.system(size: hudValueSize, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(tint)
                .contentTransition(.numericText())
                .lineLimit(1).minimumScaleFactor(0.6)
            if let unit {
                Text(unit).font(.caption).foregroundStyle(.secondary)
            } else if !usesTimerRow {
                Text(" ").font(.caption)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Timeline

    /// The workout timeline with its playhead. It reads only the engine, so it redraws once per tick rather
    /// than with every sensor packet that redraws the HUD.
    private struct WorkoutTimelineStrip: View {
        let session: RideSession

        private var engine: RideEngine { session.engine }

        private struct Cell: Identifiable {
            let id: Int
            let step: Int
            let start: TimeInterval
            let duration: TimeInterval
            let intensity: Double
        }

        /// The workout cut into one-minute cells (two past 90 min), coloured by zone; ramps show as stairs.
        private var cells: [Cell] {
            var out: [Cell] = []
            var offset: TimeInterval = 0
            let size: TimeInterval = engine.workout.totalDuration > 90 * 60 ? 120 : 60
            for (i, step) in engine.workout.steps.enumerated() {
                let n = max(1, Int((step.duration / size).rounded(.up)))
                let d = step.duration / Double(n)
                for k in 0..<n {
                    out.append(Cell(id: out.count, step: i, start: offset + Double(k) * d, duration: d, intensity: step.intensity(at: (Double(k) + 0.5) * d)))
                }
                offset += step.duration
            }
            return out
        }

        var body: some View {
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
                    Text("\(Format.countdown(engine.remainingTotal)) left")
                }
                .font(.footnote).foregroundStyle(.secondary)
            }
        }

        private var blockNumber: Int {
            min((engine.currentStepIndex ?? engine.workout.steps.count - 1) + 1, engine.workout.steps.count)
        }
    }

    // MARK: Target

    /// The target with the intensity buttons either side of it, so changing the effort happens where you
    /// read it. The band below shows where the live power sits against the zone.
    private var targetHero: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 0) {
                intensityButton("Easier", symbol: "minus", delta: -0.05, disabled: engine.intensityScale <= 0.8)
                VStack(spacing: 0) {
                    Text("Target").font(.footnote.weight(.medium)).textCase(.uppercase).foregroundStyle(.secondary).tracking(1)
                    Text(engine.targetWatts.map { "\($0)" } ?? "–")
                        .font(.system(size: 92, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white)
                        .contentTransition(.numericText())
                        .padding(.vertical, -10)
                        .lineLimit(1).minimumScaleFactor(0.6)
                    HStack(spacing: 6) {
                        Text("W").font(.title3.weight(.semibold)).foregroundStyle(.secondary)
                        if engine.intensityScale != 1 {
                            Text(String(format: "%+.0f %%", (engine.intensityScale - 1) * 100))
                                .font(.subheadline.weight(.semibold).monospacedDigit())
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 8).padding(.vertical, 2)
                                .background(Color.orange.opacity(0.18), in: Capsule())
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                intensityButton("Harder", symbol: "plus", delta: 0.05, disabled: engine.intensityScale >= 1.2)
            }
            .animation(.default, value: engine.intensityScale)
            toleranceBand.padding(.top, 10)
            HStack(spacing: 6) {
                Text(zoneText).foregroundStyle(powerTint).fontWeight(.semibold)
                if let inZone = session.blockInZonePercent {
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

    private func intensityButton(_ title: LocalizedStringKey, symbol: String, delta: Double, disabled: Bool) -> some View {
        VStack(spacing: 4) {
            Button { session.adjustIntensity(by: delta) } label: {
                Label(title, systemImage: symbol)
                    .labelStyle(.iconOnly)
                    .font(.title2.weight(.semibold))
                    .frame(width: 56, height: 56)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .disabled(disabled)
            // The button already carries the title for VoiceOver.
            Text(title).font(.caption).foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .frame(width: 72)
    }

    private var tolerance: Double { RideCommentary.zoneTolerance }

    /// The band covers ±25 % of target; the green zone is ±10 %. The live marker is clamped to the band
    /// so a wildly off number is still shown pinned at the edge. Under the band: the zone edges in gray and
    /// the live value in white under its marker.
    private var toleranceBand: some View {
        GeometryReader { geo in
            // Locals only: a nested func inside a ViewBuilder does not compile.
            let target = Double(engine.targetWatts ?? 0)
            let lo = target * 0.75
            let hi = target * 1.25
            let zoneLo = target * (1 - tolerance)
            let zoneHi = target * (1 + tolerance)
            let w = geo.size.width
            let bandH: CGFloat = 36
            let span = hi - lo
            let xLo: CGFloat = span > 0 ? w * CGFloat((zoneLo - lo) / span) : w / 2
            let xHi: CGFloat = span > 0 ? w * CGFloat((zoneHi - lo) / span) : w / 2
            let liveWatts = live.watts
            let xLive: CGFloat = span > 0 ? w * CGFloat((min(max(Double(liveWatts ?? 0), lo), hi) - lo) / span) : w / 2
            ZStack(alignment: .topLeading) {
                Capsule().fill(Color(.secondarySystemBackground)).frame(height: bandH)
                RoundedRectangle(cornerRadius: 4)
                    .fill(LinearGradient(colors: [.green.opacity(0.95), .green.opacity(0.7)], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(xHi - xLo, 6), height: bandH)
                    .offset(x: xLo)
                if liveWatts != nil {
                    Capsule().fill(.white)
                        .frame(width: 5, height: bandH + 10)
                        .shadow(color: .white.opacity(0.8), radius: 4)
                        .offset(x: xLive - 2.5, y: -5)
                }
                ZStack(alignment: .topLeading) {
                    Text("\(Int(zoneLo.rounded()))").foregroundStyle(.secondary)
                        .frame(width: 60).offset(x: xLo - 30)
                    Text("\(Int(zoneHi.rounded()))").foregroundStyle(.secondary)
                        .frame(width: 60).offset(x: xHi - 30)
                    if let watts = liveWatts {
                        Text("\(watts)").foregroundStyle(.white).fontWeight(.semibold)
                            .padding(.horizontal, 4).background(Color.black)
                            .frame(width: 60).offset(x: min(max(xLive - 30, -4), w - 56))
                    }
                }
                .font(.subheadline.monospacedDigit())
                // A three-digit value shrinks inside its 60-pt slot instead of wrapping at accessibility sizes.
                .lineLimit(1).minimumScaleFactor(0.5)
                .offset(y: bandH + 6)
            }
        }
        .frame(height: 36 + 6 + bandLabelHeight)
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
            Text(Format.countdown(engine.remainingInStep))
                .font(.system(size: 60, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
                .contentTransition(.numericText())
                .lineLimit(1).minimumScaleFactor(0.6)
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
                VStack(alignment: .leading, spacing: 1) {
                    if let i = engine.currentStepIndex, i + 1 < engine.workout.steps.count {
                        let next = engine.workout.steps[i + 1]
                        Text("Up next").font(.caption).foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            Text(next.name).fontWeight(.semibold).foregroundStyle(.white).lineLimit(1).layoutPriority(1)
                            Text("· \(stepWatts(next)) · \(Format.clock(next.duration))").foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                        }
                    } else {
                        Text("Last block").font(.caption).foregroundStyle(.secondary)
                        Text("Finish strong").fontWeight(.semibold).foregroundStyle(.white)
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            }
            .font(.subheadline)
            .padding(.horizontal, 14).padding(.vertical, 10)
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

    private var sparkline: some View {
        VStack(spacing: 4) {
            HStack {
                Text("Power (last 2 min)").font(.caption.weight(.medium)).textCase(.uppercase).foregroundStyle(.secondary).tracking(0.6)
                Spacer()
                Text(live.watts.map { "\($0) W" } ?? "–").font(.callout.weight(.semibold).monospacedDigit()).foregroundStyle(powerTint)
            }
            PowerSparklineChart(session: session)
        }
    }

    /// The last two minutes of recorded power. It reads only the engine, so the chart redraws once per tick
    /// rather than with every sensor packet that redraws the HUD.
    private struct PowerSparklineChart: View {
        let session: RideSession

        private var engine: RideEngine { session.engine }

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

        private func yMax(seen: Int) -> Int {
            let peak = engine.workout.steps.map { max($0.startIntensity, $0.endIntensity) }.max() ?? 1
            let planned = Double(engine.ftp) * peak * engine.intensityScale
            return Int((max(planned, Double(seen), 100) * 1.15 / 20).rounded(.up)) * 20
        }

        var body: some View {
            let points = recent
            Chart {
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
            .chartYScale(domain: 0...yMax(seen: points.map(\.watts).max() ?? 0))
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3])).foregroundStyle(.white.opacity(0.12))
                    AxisValueLabel().font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .frame(height: 72)
        }
    }

    // MARK: Coach

    /// A compact preview; tapping captures this message so newer captions cannot replace it mid-read.
    @ViewBuilder private var coachLine: some View {
        if let commentator = session.commentator, commentator.captionsEnabled {
            Button {
                if let caption = commentator.caption { coachMessage = CoachMessage(text: caption.line.caption) }
            } label: {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: commentator.caption.map { moodSymbol($0.line.mood) } ?? "waveform")
                        .foregroundStyle(commentator.caption.map { moodTint($0.line.mood) } ?? .secondary)
                        .font(.title2)
                        .frame(width: coachIconWidth)
                        .symbolEffect(.variableColor.iterative, isActive: commentator.thinking)
                    if let caption = commentator.caption {
                        Text(caption.line.caption)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white)
                            .lineLimit(2).minimumScaleFactor(0.85)
                    } else {
                        Text("Coach").font(.subheadline).foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                    if commentator.caption != nil {
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(minHeight: 40)
                .padding(.horizontal, 14).padding(.vertical, 6)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .disabled(commentator.caption == nil)
            .accessibilityLabel("Read full coach message")
            .accessibilityValue(commentator.caption?.line.caption ?? String(localized: "Coach"))
            .animation(.default, value: commentator.caption)
        }
    }

    private var rideMenu: some View {
        Menu {
            Toggle(isOn: Binding(get: { session.countdownBeepsEnabled }, set: { session.countdownBeepsEnabled = $0 })) {
                Label("Block countdown beeps", systemImage: "bell")
            }
            if let commentator = session.commentator {
                Toggle(isOn: Binding(get: { commentator.voiceEnabled }, set: { commentator.voiceEnabled = $0 })) { Label("Voice", systemImage: "speaker.wave.2") }
                Toggle(isOn: Binding(get: { commentator.captionsEnabled }, set: { commentator.captionsEnabled = $0 })) { Label("Captions", systemImage: "captions.bubble") }
            }
        } label: {
            Image(systemName: session.commentator?.thinking == true ? "waveform" :
                    (session.commentator?.voiceEnabled == true ? "speaker.wave.2.fill" :
                        (session.countdownBeepsEnabled ? "bell.fill" : "speaker.slash.fill")))
                .symbolEffect(.variableColor.iterative, isActive: session.commentator?.thinking == true)
        }
        .accessibilityLabel("Ride audio and captions")
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

    /// Pause/Resume and End ride (asks first). Intensity lives next to the target.
    private var controls: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 10) { controlButtons }
            } else {
                HStack(spacing: 12) { controlButtons }
            }
        }
        .controlSize(.large)
        .lineLimit(1).minimumScaleFactor(0.5)
    }

    @ViewBuilder private var controlButtons: some View {
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
}

#if DEBUG
struct RideHUDPreview: View {
    @State private var session = RideSession.hudPreview(
        longRide: !ProcessInfo.processInfo.arguments.contains("--cadencia-preview-short-ride"))

    var body: some View {
        NavigationStack { RideView(session: session, onFinish: { _ in }) }
    }
}
#endif
