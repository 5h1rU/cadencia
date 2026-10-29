import SwiftUI
import CadenciaCore

/// The home screen, read top to bottom like a coach's morning note: what your body says today,
/// the session block by block, the signals behind the verdict, a quick check-in, and only then housekeeping.
struct TodayView: View {
    @Environment(AppModel.self) private var model
    @State private var showDevices = false
    @State private var showFTPReview = false
    @State private var editingCheckIn = false

    var body: some View {
        NavigationStack {
            List {
                if let error = model.syncError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                            .font(.footnote)
                    }
                }

                briefingSection
                workoutSection
                if let week = ai?.week, !week.isEmpty, model.todayWorkout != nil { weekSection(week) }
                recoverySection
                if let event = model.thisWeekEvent { eventSection(event) }
                checkInSection
                ftpSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle(Format.day(model.today))
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if model.isSyncing { ProgressView() } else {
                        Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                    }
                }
            }
            .refreshable { await model.refresh() }
            .sheet(isPresented: $showFTPReview) { FTPReviewView() }
            .fullScreenCover(isPresented: $showDevices) {
                if let workout = model.todayWorkout { PreRideFlow(workout: workout, plannedSession: model.plannedToday) }
            }
        }
    }

    // MARK: Coach briefing

    private var ai: DailyPrescription? { model.state.today?.day == model.today ? model.state.today?.ai : nil }

    @ViewBuilder private var briefingSection: some View {
        Section {
            if let readiness = model.readiness, let note = model.coachNote {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        Image(systemName: readiness.level.symbol)
                        Text(readiness.level.title)
                        Spacer()
                        coachBadge
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(readiness.level.tint)
                    Text(note)
                        .font(.body)
                        .lineSpacing(2)
                    ForEach(ai?.flags ?? [], id: \.self) { flag in
                        Label(flagText(flag), systemImage: "flag").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
                if let notice = model.coachNotice {
                    Label(notice, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.secondary)
                } else if !model.aiCoachAvailable {
                    Label("Sign in with ChatGPT in Settings → Coach to have the AI coach decide your days.", systemImage: "sparkles")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if model.aiCoachAvailable {
                    Button {
                        Task { await model.askCoachForToday(force: true) }
                    } label: {
                        Label("Ask the coach again", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(model.coachThinking)
                }
            } else if model.workingFTP == nil {
                Label("Set an FTP in Intervals.icu to get prescriptions.", systemImage: "exclamationmark.circle")
            } else {
                ProgressView("Preparing your day…")
            }
        } header: {
            Text("Your coach")
        } footer: {
            if let ai {
                Text("Decided \(ai.generatedAt.formatted(date: .omitted, time: .shortened)) from your recovery, load, power and plan. The on-device rules checked every number before it reached the trainer.")
            }
        }
    }

    /// Who wrote the note: the model, or the on-device rules while it thinks or when it is off.
    @ViewBuilder private var coachBadge: some View {
        Group {
            if model.coachThinking {
                HStack(spacing: 4) { ProgressView().controlSize(.mini); Text("Coach is deciding…") }
            } else if let ai {
                Label("AI coach · \(ai.model)", systemImage: "sparkles")
            } else {
                Label("On-device rules", systemImage: "cpu")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func flagText(_ flag: String) -> LocalizedStringKey {
        switch flag {
        case "ftp_review": return "The coach thinks your FTP needs a review."
        case "illness", "sick": return "Signs of illness: the coach is holding back intensity."
        case "overreaching": return "Load has ramped quickly: the coach is protecting recovery."
        default: return LocalizedStringKey(flag.replacingOccurrences(of: "_", with: " "))
        }
    }

    /// The coach's shape for the next days, one chip per day.
    private func weekSection(_ week: [DailyPrescription.DayOutlook]) -> some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(week) { day in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(day.day == model.today ? String(localized: "Today") : Format.shortDay(day.day))
                                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                            Image(systemName: day.kind.symbol).foregroundStyle(day.kind.tint)
                            Text(day.kind.title).font(.caption.weight(.medium)).lineLimit(1)
                            Text(day.kind == .rest ? "—" : Format.minutes(TimeInterval(day.minutes * 60)))
                                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        .padding(10)
                        .frame(width: 96, alignment: .leading)
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(alignment: .topTrailing) {
                            if day.day == model.today { Circle().fill(Color.accentColor).frame(width: 6, height: 6).padding(8) }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
        } header: {
            Text("The week ahead")
        } footer: {
            if model.state.plan != nil {
                Text("Mirrored to your Intervals.icu calendar. Tell the coach about changes and it re-shapes the week.")
            }
        }
    }

    // MARK: Workout

    @ViewBuilder private var workoutSection: some View {
        if let workout = model.todayWorkout, let ftp = model.workingFTP {
            Section {
                if workout.kind == .rest || workout.steps.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(workout.name).font(.title3.weight(.semibold))
                        Text("No ride today.").foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                } else {
                    NavigationLink { WorkoutDetailView(workout: workout, ftp: ftp) } label: {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(workout.name).font(.title3.weight(.semibold))
                                Spacer()
                                Text(Format.minutes(workout.totalDuration)).font(.subheadline).foregroundStyle(.secondary)
                            }
                            VStack(spacing: 10) {
                                ForEach(workout.outline) { row in outlineRow(row, workout: workout, ftp: ftp) }
                            }
                            Divider()
                            HStack(spacing: 20) {
                                metric("Target", value: Format.watts(workout.targetWatts(ftp: ftp, at: mainBlockOffset(workout))))
                                if let ceiling = workout.intensityCeiling {
                                    metric("Ceiling", value: Format.watts(Int((ceiling * Double(ftp)).rounded())))
                                }
                                metric("Load", value: "\(workout.estimatedLoad)")
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    Button { showDevices = true } label: {
                        Label("Start on trainer", systemImage: "play.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .listRowBackground(Color.clear)
                }
            } header: {
                Text("Today's workout")
            }
        }
    }

    private func outlineRow(_ row: Workout.OutlineRow, workout: Workout, ftp: Int) -> some View {
        let mean = (row.work.startIntensity + row.work.endIntensity) / 2
        return HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Zone.color(for: mean))
                .frame(width: 4, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                if row.isSet {
                    Text("\(row.repeats) × \(row.title)")
                } else {
                    Text(row.title)
                }
                HStack(spacing: 4) {
                    Text(wattsText(row.work, workout: workout, ftp: ftp))
                    Text("·")
                    if let rest = row.rest {
                        Text("\(Format.minutes(row.work.duration)) on, \(Format.minutes(rest.duration)) easy")
                    } else {
                        Text(Zone.name(for: mean))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Text(Format.minutes(row.totalDuration))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func wattsText(_ step: WorkoutStep, workout: Workout, ftp: Int) -> String {
        func watts(_ i: Double) -> Int {
            let capped = workout.intensityCeiling.map { min(i, $0) } ?? i
            return Int((capped * Double(ftp)).rounded())
        }
        return step.isRamp ? "\(watts(step.startIntensity))→\(watts(step.endIntensity)) W" : "\(watts(step.startIntensity)) W"
    }

    // MARK: Recovery signals

    private var recoverySection: some View {
        Section {
            NavigationLink { RecoveryView() } label: {
                VStack(spacing: 12) {
                    signalRow("HRV", name: "hrv", missing: "No HRV today",
                              value: model.todayWellness?.hrvMs.map { String(format: "%.0f ms", $0) })
                    signalRow("Sleep", name: "sleep", missing: "No sleep data",
                              value: model.todayWellness?.sleepSeconds.map { Format.hours($0) })
                    signalRow("Resting HR", name: "restingHR", missing: "No resting HR",
                              value: model.todayWellness?.restingHR.map { "\($0) bpm" })
                    signalRow("Fatigue", name: "fatigue", missing: "No load data",
                              value: model.todayWellness?.atl.map { String(format: "%.0f ATL", $0) })
                    signalRow("Form", name: "form", missing: "No load data",
                              value: model.todayWellness?.tsb.map { String(format: "%+.0f TSB", $0) })
                }
                .padding(.vertical, 6)
            }
        } header: {
            Text("Recovery signals")
        } footer: {
            if let r = model.readiness, !r.isSufficientlyInformed {
                Text("Few recovery signals today, so the prescription is conservative. Connect Apple Health or wear your watch to sleep for a sharper call.")
            }
        }
    }

    private func signalRow(_ title: LocalizedStringKey, name: String, missing: LocalizedStringKey, value: String?) -> some View {
        let signal = model.readiness?.signals.first { $0.name == name }
        let informed = value != nil && signal?.verdict != .missing
        let tint: Color = informed ? (signal?.verdictTint ?? .secondary) : Color(.systemGray4)
        return HStack(spacing: 10) {
            Circle().fill(tint).frame(width: 8, height: 8)
            Text(title)
            Spacer()
            if let value {
                Text(value).font(.subheadline.monospacedDigit())
                if let signal, signal.verdict != .missing {
                    Text(signal.verdictText)
                        .font(.caption)
                        .foregroundStyle(signal.verdictTint)
                        .frame(width: 86, alignment: .trailing)
                }
            } else {
                Text(missing).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Event

    private func eventSection(_ event: TrainingEvent) -> some View {
        Section("This week") {
            NavigationLink { EventPrepView(event: event) } label: {
                Label {
                    VStack(alignment: .leading) {
                        Text(event.name)
                        Text("\(Format.day(event.day)) · \(model.today.days(until: event.day)) days").font(.footnote).foregroundStyle(.secondary)
                    }
                } icon: { Image(systemName: event.isRace ? "flag.checkered" : "person.3") }
            }
        }
    }

    // MARK: Check-in

    private var feedback: SubjectiveFeedback? { model.state.feedback(for: model.today) }

    @ViewBuilder private var checkInSection: some View {
        Section {
            if let legs = feedback?.legs, !editingCheckIn {
                HStack {
                    Label {
                        if let m = feedback?.motivation {
                            Text("Legs \(Text(legs.title)) · motivation \(m)/5")
                        } else {
                            Text("Legs \(Text(legs.title))")
                        }
                    } icon: {
                        Image(systemName: "checkmark.circle").foregroundStyle(.green)
                    }
                    .foregroundStyle(.secondary)
                    Spacer()
                    Button("Change") { editingCheckIn = true }.font(.subheadline)
                }
            } else {
                Picker("Legs", selection: Binding(
                    get: { feedback?.legs },
                    set: { model.recordFeeling($0, motivation: feedback?.motivation) }
                )) {
                    Text("Fresh").tag(SubjectiveFeedback.Legs?.some(.fresh))
                    Text("OK").tag(SubjectiveFeedback.Legs?.some(.ok))
                    Text("Heavy").tag(SubjectiveFeedback.Legs?.some(.heavy))
                }
                .pickerStyle(.segmented)
                HStack {
                    Text("Motivation")
                    Spacer()
                    HStack(spacing: 8) {
                        ForEach(1...5, id: \.self) { n in
                            Button {
                                model.recordFeeling(feedback?.legs ?? .ok, motivation: n)
                            } label: {
                                Image(systemName: n <= (feedback?.motivation ?? 0) ? "circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundStyle(n <= (feedback?.motivation ?? 0) ? Color.accentColor : Color(.systemGray3))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if feedback?.legs != nil {
                    Button("Done") { editingCheckIn = false }.frame(maxWidth: .infinity)
                }
            }
        } header: {
            Text("Check-in")
        } footer: {
            Text("Your own words are one more signal for the coach. They can soften today's session, never harden it.")
        }
    }

    // MARK: FTP

    @ViewBuilder private var ftpSection: some View {
        if let proposal = model.ftpProposal, let current = model.workingFTP {
            Section {
                Button { showFTPReview = true } label: {
                    HStack {
                        Label("FTP estimate \(proposal) W, working \(current) W", systemImage: "chart.line.uptrend.xyaxis")
                        Spacer()
                        Text("Review")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Helpers

    private func metric(_ title: LocalizedStringKey, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline.monospacedDigit())
        }
    }

    /// The elapsed offset of the longest non-warmup block, used to show "the" target of the session.
    private func mainBlockOffset(_ workout: Workout) -> TimeInterval {
        var elapsed: TimeInterval = 0
        var best: (offset: TimeInterval, intensity: Double) = (0, 0)
        for step in workout.steps {
            let mean = (step.startIntensity + step.endIntensity) / 2
            if mean > best.intensity { best = (elapsed + step.duration / 2, mean) }
            elapsed += step.duration
        }
        return best.offset
    }
}

extension SubjectiveFeedback.Legs {
    var title: LocalizedStringKey {
        switch self {
        case .fresh: return "fresh"
        case .ok: return "OK"
        case .heavy: return "heavy"
        }
    }
}

#Preview {
    TodayView().environment(PreviewData.model())
}
