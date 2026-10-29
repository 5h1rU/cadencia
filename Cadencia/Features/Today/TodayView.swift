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
                        WorkoutProfileView(workout: workout).frame(height: 56).padding(.top, 4)
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
                Text("Today's session")
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

/// Compact bar profile of a workout, intensity as height, colored by zone.
struct WorkoutProfileView: View {
    let workout: Workout

    var body: some View {
        GeometryReader { geo in
            let total = max(workout.totalDuration, 1)
            let maxIntensity = max(workout.steps.map { max($0.startIntensity, $0.endIntensity) }.max() ?? 1, 1)
            HStack(alignment: .bottom, spacing: 1) {
                ForEach(workout.steps) { step in
                    let width = max(geo.size.width * step.duration / total - 1, 1)
                    Rectangle()
                        .fill(zoneColor((step.startIntensity + step.endIntensity) / 2))
                        .frame(width: width, height: max(geo.size.height * ((step.startIntensity + step.endIntensity) / 2) / maxIntensity, 2))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func zoneColor(_ intensity: Double) -> Color {
        switch intensity {
        case ..<0.55: return .gray
        case ..<0.75: return .blue
        case ..<0.90: return .green
        case ..<1.05: return .yellow
        case ..<1.20: return .orange
        default: return .red
        }
    }
}

#Preview {
    TodayView().environment(PreviewData.model())
}
