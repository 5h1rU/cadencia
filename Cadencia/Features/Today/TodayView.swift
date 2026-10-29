import SwiftUI
import CadenciaCore

struct TodayView: View {
    @Environment(AppModel.self) private var model
    @State private var showDevices = false
    @State private var showFTPReview = false

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

                if let proposal = model.ftpProposal, let current = model.workingFTP {
                    Section {
                        Button { showFTPReview = true } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("FTP looks like \(proposal) W, not \(current) W")
                                    Text("Review the evidence before zones change.").font(.footnote).foregroundStyle(.secondary)
                                }
                            } icon: { Image(systemName: "chart.line.uptrend.xyaxis") }
                        }
                    }
                }

                prescriptionSection
                coachSection
                if let week = model.state.today?.ai?.week, !week.isEmpty, model.todayWorkout != nil { weekSection(week) }
                recoverySection
                if let event = model.thisWeekEvent { eventSection(event) }
                feelSection
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

    // MARK: Sections

    @ViewBuilder private var prescriptionSection: some View {
        if let workout = model.todayWorkout, let readiness = model.readiness, let ftp = model.workingFTP {
            Section {
                NavigationLink { WorkoutDetailView(workout: workout, ftp: ftp) } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label(readiness.level.title, systemImage: readiness.level.symbol)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(readiness.level.tint)
                            Spacer()
                            Text(Format.minutes(workout.totalDuration)).foregroundStyle(.secondary).font(.subheadline)
                        }
                        Text(workout.name).font(.title2.weight(.semibold))
                        Text(workout.rationale).font(.subheadline).foregroundStyle(.secondary)
                        WorkoutProfileView(workout: workout, ftp: ftp, compact: true).frame(height: 64).padding(.top, 4)
                        HStack(spacing: 12) {
                            ForEach(legend, id: \.0) { item in
                                HStack(spacing: 4) {
                                    Circle().fill(item.1).frame(width: 7, height: 7)
                                    Text(item.0).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                        HStack(spacing: 16) {
                            metric("Target", value: Format.watts(workout.targetWatts(ftp: ftp, at: mainBlockOffset(workout))))
                            if let ceiling = workout.intensityCeiling {
                                metric("Ceiling", value: Format.watts(Int((ceiling * Double(ftp)).rounded())))
                            }
                            metric("Load", value: "\(workout.estimatedLoad)")
                        }
                    }
                    .padding(.vertical, 4)
                }
                if workout.kind != .rest {
                    Button { showDevices = true } label: {
                        Label("Start on trainer", systemImage: "play.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .listRowBackground(Color.clear)
                }
            } header: {
                HStack {
                    Text("Today's session")
                    Spacer()
                    coachBadge
                }
            } footer: {
                if !readiness.isSufficientlyInformed {
                    Text("Few recovery signals today, so the prescription is conservative. Connect Apple Health or wear your watch to sleep for a sharper call.")
                }
            }
        } else {
            Section("Today's session") {
                if model.workingFTP == nil {
                    Label("Set an FTP in Intervals.icu to get prescriptions.", systemImage: "exclamationmark.circle")
                } else {
                    ProgressView("Preparing your day…")
                }
            }
        }
    }

    /// Who decided today, shown in the session header: the model, or the on-device rules while it thinks or when it is off.
    @ViewBuilder private var coachBadge: some View {
        if model.coachThinking {
            HStack(spacing: 4) { ProgressView().controlSize(.mini); Text("Coach is deciding…") }
        } else if let ai = model.state.today?.ai, model.state.today?.day == model.today {
            Label("AI coach · \(ai.model)", systemImage: "sparkles").labelStyle(.titleAndIcon)
        } else {
            Label("On-device rules", systemImage: "cpu")
        }
    }

    /// The coach's words for today: the full note, any flags, and a way to ask again.
    @ViewBuilder private var coachSection: some View {
        if model.todayWorkout != nil, model.aiCoachAvailable || model.state.today?.ai != nil {
            Section {
                if let ai = model.state.today?.ai, model.state.today?.day == model.today {
                    if !ai.coachNote.isEmpty {
                        Label { Text(ai.coachNote) } icon: { Image(systemName: "quote.opening") }
                    }
                    ForEach(ai.flags, id: \.self) { flag in
                        Label(flagText(flag), systemImage: "flag").font(.footnote).foregroundStyle(.secondary)
                    }
                } else if let notice = model.coachNotice {
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
            } header: {
                Text("Coach")
            } footer: {
                if let ai = model.state.today?.ai, model.state.today?.day == model.today {
                    Text("Decided \(ai.generatedAt.formatted(date: .omitted, time: .shortened)) from your recovery, load, power and plan. The on-device rules checked every number before it reached the trainer.")
                }
            }
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

    private func flagText(_ flag: String) -> LocalizedStringKey {
        switch flag {
        case "ftp_review": return "The coach thinks your FTP needs a review."
        case "illness", "sick": return "Signs of illness: the coach is holding back intensity."
        case "overreaching": return "Load has ramped quickly: the coach is protecting recovery."
        default: return LocalizedStringKey(flag.replacingOccurrences(of: "_", with: " "))
        }
    }

    private var recoverySection: some View {
        Section {
            NavigationLink { RecoveryView() } label: {
                HStack(spacing: 16) {
                    recoveryMetric("HRV", value: model.todayWellness?.hrvMs.map { String(format: "%.0f", $0) } ?? "–", unit: "ms", signal: signal("hrv"))
                    recoveryMetric("Sleep", value: model.todayWellness?.sleepSeconds.map { Format.hours($0) } ?? "–", unit: "", signal: signal("sleep"))
                    recoveryMetric("Fatigue", value: model.todayWellness?.atl.map { String(format: "%.0f", $0) } ?? "–", unit: "ATL", signal: signal("fatigue"))
                    recoveryMetric("Form", value: model.todayWellness?.tsb.map { String(format: "%+.0f", $0) } ?? "–", unit: "TSB", signal: signal("form"))
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text("Recovery")
        } footer: {
            if let r = model.readiness { Text(r.summary) }
        }
    }

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

    private var feelSection: some View {
        Section {
            Picker("Legs", selection: Binding(
                get: { model.state.feedback(for: model.today)?.legs },
                set: { model.recordFeeling($0) }
            )) {
                Text("Fresh").tag(SubjectiveFeedback.Legs?.some(.fresh))
                Text("OK").tag(SubjectiveFeedback.Legs?.some(.ok))
                Text("Heavy").tag(SubjectiveFeedback.Legs?.some(.heavy))
            }
            .pickerStyle(.segmented)
        } header: {
            Text("How do you feel?")
        } footer: {
            Text("Your answer counts as one more signal. It can soften today's session, never harden it.")
        }
    }

    // MARK: Helpers

    private func signal(_ name: String) -> Readiness.Signal? { model.readiness?.signals.first { $0.name == name } }

    /// Zones present in today's workout, for the small legend under the profile.
    private var legend: [(String, Color)] {
        guard let workout = model.todayWorkout else { return [] }
        var seen: [(String, Color)] = []
        for step in workout.steps {
            let i = (step.startIntensity + step.endIntensity) / 2
            let name = Zone.shortName(for: i)
            if !seen.contains(where: { $0.0 == name }) { seen.append((name, Zone.color(for: i))) }
        }
        return seen
    }

    private func metric(_ title: LocalizedStringKey, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline.monospacedDigit())
        }
    }

    private func recoveryMetric(_ title: LocalizedStringKey, value: String, unit: String, signal: Readiness.Signal?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(.headline.monospacedDigit())
                if !unit.isEmpty { Text(unit).font(.caption2).foregroundStyle(.secondary) }
            }
            if let signal, signal.verdict != .missing {
                Text(signal.verdictText).font(.caption2).foregroundStyle(signal.verdictTint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
