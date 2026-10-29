import SwiftUI
import CadenciaCore

/// The home screen, read top to bottom like a coach's morning note: what your body says today,
/// the session block by block, the signals behind the verdict, and only then housekeeping.
struct TodayView: View {
    @Environment(AppModel.self) private var model
    @State private var showDevices = false
    @State private var showFTPReview = false
    /// The coach's note folds to its verdict and headline once read; it opens again on the next launch.
    @State private var coachCollapsed = false

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
                if let last = model.lastRide { lastSessionSection(last) }
                recoverySection
                if let event = model.thisWeekEvent { eventSection(event) }
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
            if !model.aiCoachAvailable {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Connect your coach", systemImage: "sparkles").font(.headline)
                    Text("Cadencia's coach is an AI that reads your recovery, load, power and plan every day and decides your session. Sign in with ChatGPT to use your plan, or add an OpenAI API key.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                NavigationLink { CoachSettingsView() } label: {
                    Label("Set up the coach", systemImage: "arrow.right.circle")
                }
            } else if ai != nil, let readiness = model.readiness, coachCollapsed {
                Button {
                    withAnimation(.snappy) { coachCollapsed = false }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: readiness.level.symbol).foregroundStyle(readiness.level.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(readiness.level.title).font(.subheadline.weight(.semibold)).foregroundStyle(readiness.level.tint)
                            if let headline = model.coachNote?.headline, !headline.isEmpty {
                                Text(headline).font(.subheadline).foregroundStyle(.primary).lineLimit(1)
                            }
                        }
                        Spacer()
                        if model.coachThinking { ProgressView().controlSize(.mini) }
                        Image(systemName: "chevron.down").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 2)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show the coach's note")
            } else if let ai, let readiness = model.readiness {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 6) {
                        Image(systemName: readiness.level.symbol)
                        Text(readiness.level.title)
                        Spacer()
                        coachBadge
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(readiness.level.tint)
                    if let note = model.coachNote {
                        if !note.headline.isEmpty {
                            Text(note.headline).font(.title3.weight(.semibold))
                        }
                        if !note.body.isEmpty {
                            notePart("Your body", text: note.body)
                        }
                        if !note.session.isEmpty {
                            notePart("Today", text: note.session)
                        }
                        if let watch = note.watch {
                            notePart("Keep in mind", text: watch)
                        }
                    }
                    ForEach(ai.flags, id: \.self) { flag in
                        Label(flagText(flag), systemImage: "flag").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
                if let notice = model.coachNotice {
                    Label(notice, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.secondary)
                }
                askAgainButton
            } else if model.workingFTP == nil {
                Label("Set an FTP in Intervals.icu to get prescriptions.", systemImage: "exclamationmark.circle")
            } else if model.coachThinking {
                HStack(spacing: 12) {
                    ProgressView()
                    VStack(alignment: .leading, spacing: 2) {
                        Text("The coach is reading your data…")
                        Text("Recovery, load, power curve and plan. This takes a few seconds.").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            } else if let notice = model.coachNotice {
                Label(notice, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                Button("Ask the coach", systemImage: "sparkles") { Task { await model.askCoachForToday(force: true) } }
            } else if let issue = model.coachIssue {
                Label(issueText(issue), systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
            } else {
                Button("Ask the coach", systemImage: "sparkles") { Task { await model.askCoachForToday(force: true) } }
            }
        } header: {
            HStack {
                Text("Your coach")
                Spacer()
                if ai != nil, model.readiness != nil {
                    Button(coachCollapsed ? "Show" : "Hide") {
                        withAnimation(.snappy) { coachCollapsed.toggle() }
                    }
                    .font(.footnote)
                    .textCase(nil)
                }
            }
        } footer: {
            if let ai, !coachCollapsed {
                Text("Decided \(ai.generatedAt.formatted(date: .omitted, time: .shortened)) from your recovery, load, power and plan. Every number was range-checked before it reached the trainer.")
            }
        }
    }

    private func notePart(_ title: LocalizedStringKey, text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            Text(text).font(.body).lineSpacing(2)
        }
    }

    private var askAgainButton: some View {
        Button {
            Task { await model.askCoachForToday(force: true) }
        } label: {
            if model.coachThinking {
                HStack(spacing: 8) { ProgressView(); Text("Asking the coach…") }
            } else {
                Label("Ask the coach again", systemImage: "arrow.triangle.2.circlepath")
            }
        }
        .disabled(model.coachThinking)
    }

    private func issueText(_ issue: AppModel.CoachIssue) -> LocalizedStringKey {
        switch issue {
        case .usageLimit: return "You've reached the usage limit of your ChatGPT plan for now. Manage it in Settings → Coach, or wait for it to reset."
        case .notEligible: return "Your ChatGPT account can't share its plan with apps. Use an API key in Settings → Coach."
        case .signInAgain: return "ChatGPT no longer accepts this sign-in. Sign in again in Settings → Coach."
        }
    }

    /// Who wrote the note: the model, or a spinner while it thinks.
    @ViewBuilder private var coachBadge: some View {
        Group {
            if model.coachThinking {
                HStack(spacing: 4) { ProgressView().controlSize(.mini); Text("Coach is deciding…") }
            } else if let ai {
                Label("AI coach · \(ai.model)", systemImage: "sparkles")
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

    // MARK: Last session

    /// The most recent ride and where its debrief stands; tapping opens the full read.
    private func lastSessionSection(_ entry: AppState.RideIndexEntry) -> some View {
        let report = model.ride(id: entry.id)?.debrief
        let status = model.debriefStatus[entry.id]
        return Section {
            NavigationLink {
                RideDebriefView(rideID: entry.id)
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(entry.name).font(.headline)
                        Spacer()
                        Text(Format.relative(entry.startedAt)).font(.caption).foregroundStyle(.secondary)
                    }
                    if let report {
                        GradeBadge(grade: report.grade)
                        Text(report.headline).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
                    } else if case .failed(let message) = status {
                        Label(message, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                    } else if status != nil {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("The coach is reading your session…").font(.footnote).foregroundStyle(.secondary)
                        }
                    } else {
                        Text("\(Format.minutes(entry.duration)) · \(Format.watts(entry.averageWatts)) · Load \(entry.load.map { "\($0)" } ?? "–")")
                            .font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("Last session")
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
                        Label("Start on trainer", systemImage: "play.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
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
                              value: model.latestLoad?.atl.map { String(format: "%.0f ATL", $0) })
                    signalRow("Form", name: "form", missing: "No load data",
                              value: model.latestLoad?.tsb.map { String(format: "%+.0f TSB", $0) })
                }
                .padding(.vertical, 6)
            }
        } header: {
            Text("Recovery signals")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if let load = model.latestLoad, load.day != model.today {
                    Text("Fatigue and form are Intervals.icu's numbers from \(Format.shortDay(load.day)); it has not written today's yet.")
                }
                if !model.measuredSignals.isSufficientlyInformed {
                    Text("Few recovery signals today, so the prescription is conservative. Connect Apple Health or wear your watch to sleep for a sharper call.")
                }
            }
        }
    }

    private func signalRow(_ title: LocalizedStringKey, name: String, missing: LocalizedStringKey, value: String?) -> some View {
        let signal = model.measuredSignals.signals.first { $0.name == name }
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

#Preview {
    TodayView().environment(PreviewData.model())
}
