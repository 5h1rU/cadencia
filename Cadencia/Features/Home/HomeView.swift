import SwiftUI
import CadenciaCore

/// Training load and recovery first, followed by a compact coach link and the day ahead.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showDevices = false
    @State private var showFTPReview = false
    @State private var recoveryFocus: RecoveryView.Focus?
    @State private var recoveryInformationExpanded = false
    @State private var loadInformationExpanded = false

    var body: some View {
        NavigationStack {
            List {
                trainingLoadSection
                recoverySection

                if let error = model.syncError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                            .font(.footnote)
                    }
                }

                briefingSection
                workoutSection
                if let event = model.thisWeekEvent { eventSection(event) }
                if let last = model.lastRide { lastSessionSection(last) }
                Section {
                    NavigationLink { PlannedRideRouteView(day: model.today, chooseDate: true) } label: { Label("Plan a route", systemImage: "map") }
                    NavigationLink { RideHistoryView() } label: { Label("Ride history", systemImage: "clock.arrow.circlepath") }
                }
                if let week = ai?.week, !week.isEmpty, model.todayWorkout != nil { weekSection(week) }
                CyclistProfileSection()
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Home")
            .navigationBarTitleDisplayMode(.large)
            .navigationDestination(item: $recoveryFocus) { focus in RecoveryView(focus: focus) }
            .refreshable { await model.refresh() }
            .task(id: "\(model.athleteID):\(model.isSignedIn):\(model.aiCoachAvailable)") {
                await model.generateCyclistProfile(automatically: true)
            }
            .sheet(isPresented: $showFTPReview) { FTPReviewView() }
            .fullScreenCover(isPresented: $showDevices) {
                if let workout = model.todayWorkout { PreRideFlow(workout: workout, plannedSession: model.plannedToday) }
            }
        }
    }

    // MARK: Coach briefing

    private var ai: DailyPrescription? { model.state.today?.day == model.today ? model.state.today?.ai : nil }

    /// Use the same headline as the detail screen, including the completed ride's debrief.
    private var coachHeadline: String? {
        let headline: String?
        if model.isTodayWorkoutCompleted {
            if let id = model.completedRideToday?.id, let ride = model.ride(id: id), !RideDebrief.requiresRefresh(ride) {
                headline = ride.debrief?.headline
                    ?? ride.debriefNote?.debriefText.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init)
            } else {
                headline = nil
            }
        } else {
            headline = model.coachNote?.headline
        }
        guard let headline = headline?.trimmingCharacters(in: .whitespacesAndNewlines), !headline.isEmpty else { return nil }
        return headline
    }

    private var briefingSection: some View {
        HomeSection("Your coach") {
            NavigationLink {
                CoachBriefingView()
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    if let headline = coachHeadline {
                        Text(headline).font(.subheadline)
                    } else if model.isTodayWorkoutCompleted {
                        Text("Today's session is complete.").font(.subheadline)
                    } else if model.coachThinking {
                        Text("The coach is reading your data…").font(.subheadline)
                    } else if !model.aiCoachAvailable {
                        Text("Set up the coach").font(.subheadline)
                    } else if model.coachNotice != nil || model.coachIssue != nil {
                        Text("Your coach needs attention").font(.subheadline).foregroundStyle(.orange)
                    } else {
                        Text("Ask the coach").font(.subheadline)
                    }
                    if coachHeadline != nil {
                        if model.coachThinking {
                            Text("The coach is reading your data…").font(.caption).foregroundStyle(.secondary)
                        } else if model.coachNotice != nil || model.coachIssue != nil {
                            Text("Your coach needs attention").font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 6)
            }
            .accessibilityIdentifier("coach-briefing-link")
        }
    }

    /// The coach's shape for the next days, one chip per day.
    private func weekSection(_ week: [DailyPrescription.DayOutlook]) -> some View {
        InfoSection(hasInformation: model.state.plan != nil) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(week) { day in
                        NavigationLink {
                            weekDestination(day)
                        } label: {
                            weekDayCard(day)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Open session details")
                        .accessibilityIdentifier("week-day-\(day.day.iso)")
                    }
                }
                .padding(.vertical, 4)
            }
            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
        } header: {
            Text("The week ahead").font(.headline)
                .frame(minHeight: 44, alignment: .leading)
        } information: {
            if model.state.plan != nil {
                Text("Mirrored to your Intervals.icu calendar. Tell the coach about changes and it re-shapes the week.")
            }
        }
    }

    private func weekDayCard(_ day: DailyPrescription.DayOutlook) -> some View {
        let isToday = day.day == model.today
        let completed = isToday && model.isTodayWorkoutCompleted
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(isToday ? String(localized: "Today") : Format.shortDay(day.day))
                    .font(.caption2.weight(.semibold))
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                    .accessibilityHidden(true)
            }
            .foregroundStyle(isToday ? Color.accentColor : .secondary)
            Image(systemName: completed ? "checkmark.circle.fill" : day.kind.symbol)
                .foregroundStyle(completed ? .green : day.kind.tint)
                .accessibilityHidden(true)
            Text(day.kind.title).font(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 4 : 2, reservesSpace: true)
            Text(day.kind == .rest ? "—" : (day.minutes > 0 ? Format.minutes(TimeInterval(day.minutes * 60)) : String(localized: "Time TBD")))
                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(width: dynamicTypeSize.isAccessibilitySize ? 160 : 104, alignment: .leading)
        .background(isToday ? Color.accentColor.opacity(0.08) : Color(.tertiarySystemFill),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            if isToday {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.3), lineWidth: 1)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityValue(completed ? Text("Completed") : Text(""))
    }

    @ViewBuilder private func weekDestination(_ day: DailyPrescription.DayOutlook) -> some View {
        if day.day == model.today, let ride = model.completedRideToday {
            RideDebriefView(rideID: ride.id)
        } else if let session = model.state.session(on: day.day), let ride = model.completedRide(for: session) {
            RideDebriefView(rideID: ride.id)
        } else if day.day == model.today, let workout = model.todayWorkout, let ftp = model.workingFTP,
                  workout.kind != .rest, !workout.steps.isEmpty {
            WorkoutDetailView(workout: model.todayRideLocation == .outdoor ? (model.outdoorWorkout?.workout ?? workout) : workout,
                              ftp: model.todayRideLocation == .outdoor ? (model.outdoorFTP ?? ftp) : ftp)
        } else {
            PlannedDayView(day: day)
        }
    }

    // MARK: Last session

    /// The most recent ride and where its debrief stands; tapping opens the full read.
    private func lastSessionSection(_ entry: AppState.RideIndexEntry) -> some View {
        let report = model.ride(id: entry.id)?.debrief
        let status = model.debriefStatus[entry.id]
        return HomeSection("Last session") {
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
        }
    }

    // MARK: Workout

    @ViewBuilder private var workoutSection: some View {
        if let original = model.todayWorkout, let indoorFTP = model.workingFTP {
            let workout = model.todayRideLocation == .outdoor ? (model.outdoorWorkout?.workout ?? original) : original
            let ftp = model.todayRideLocation == .outdoor ? (model.outdoorFTP ?? indoorFTP) : indoorFTP
            HomeSection("Today's workout") {
                if model.isTodayWorkoutCompleted {
                    if let ride = model.completedRideToday {
                        NavigationLink { RideDebriefView(rideID: ride.id) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(ride.name).font(.title3.weight(.semibold))
                                Label("Completed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                                Text(Format.minutes(ride.duration)).font(.subheadline).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                    } else {
                        Label("Completed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                } else if workout.kind == .rest || workout.steps.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(workout.name).font(.title3.weight(.semibold))
                        Text("No ride today.").foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                } else {
                    if workout.kind != .strength {
                        Picker("Ride location", selection: Binding(get: { model.todayRideLocation }, set: { model.setTodayRideLocation($0) })) {
                            Text("Indoor").tag(RideLocation.indoor)
                            Text("Outdoor").tag(RideLocation.outdoor)
                        }
                        .pickerStyle(.segmented)
                        .disabled(model.coachThinking)
                    }
                    NavigationLink { WorkoutDetailView(workout: workout, ftp: ftp) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(workout.name).font(.title3.weight(.semibold))
                            Text(Format.minutes(workout.totalDuration)).font(.subheadline).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(spacing: 10) {
                            ForEach(workout.outline) { row in outlineRow(row, workout: workout, ftp: ftp) }
                        }
                        Divider()
                        workoutMetrics(workout, ftp: ftp)
                    }
                    .padding(.vertical, 4)
                    .listRowSeparator(.hidden, edges: .bottom)
                    if model.todayRideLocation == .outdoor {
                        NavigationLink { OutdoorWorkoutView() } label: {
                            Label("Prepare bike computer", systemImage: "bicycle")
                                .font(.headline)
                                .frame(maxWidth: .infinity, minHeight: 32, alignment: .center)
                        }
                    } else {
                        Button { showDevices = true } label: {
                            Text("Start on trainer")
                                .font(.headline)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity, minHeight: 32, alignment: .center)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 16, trailing: 16))
                        .listRowSeparator(.hidden)
                    }
                }
                ftpReviewRow
            }
        } else if model.ftpProposal != nil {
            HomeSection("Today's workout") { ftpReviewRow }
        }
    }

    private func workoutMetrics(_ workout: Workout, ftp: Int) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
        return layout {
            metric("Target", value: Format.watts(workout.targetWatts(ftp: ftp, at: mainBlockOffset(workout))))
            if let ceiling = workout.intensityCeiling {
                metric("Ceiling", value: Format.watts(Int((ceiling * Double(ftp)).rounded())))
            }
            metric("Load", value: "\(workout.estimatedLoad)")
        }
    }

    private func outlineRow(_ row: Workout.OutlineRow, workout: Workout, ftp: Int) -> some View {
        let mean = (row.work.startIntensity + row.work.endIntensity) / 2
        let detailsLayout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(spacing: 4))
        return HStack(alignment: dynamicTypeSize.isAccessibilitySize ? .top : .center, spacing: 12) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Zone.color(for: mean))
                .frame(width: 4, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                if row.isSet {
                    Text("\(row.repeats) × \(row.title)")
                } else {
                    Text(row.title)
                }
                detailsLayout {
                    Text(wattsText(row.work, workout: workout, ftp: ftp))
                    if !dynamicTypeSize.isAccessibilitySize { Text("·") }
                    if let rest = row.rest {
                        Text("\(Format.minutes(row.work.duration)) on, \(Format.minutes(rest.duration)) easy")
                    } else {
                        Text(Zone.name(for: mean))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if dynamicTypeSize.isAccessibilitySize {
                    Text(Format.minutes(row.totalDuration))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if !dynamicTypeSize.isAccessibilitySize {
                Spacer()
                Text(Format.minutes(row.totalDuration))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
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
        metricsSection("Recovery signals", linkLabel: "Open recovery details", identifier: "recovery-signals", focus: .recovery,
                       informationExpanded: $recoveryInformationExpanded) {
            metricLayout {
                recoveryMetric("HRV", symbol: "waveform.path.ecg", name: "hrv",
                               value: model.todayWellness?.hrvMs.map { $0.formatted(.number.precision(.fractionLength(0))) }, unit: "ms")
                Divider()
                recoveryMetric("Sleep", symbol: "moon", name: "sleep",
                               value: model.todayWellness?.sleepSeconds.map { (Double($0) / 3600).formatted(.number.precision(.fractionLength(1))) }, unit: "h")
                Divider()
                recoveryMetric("Resting HR", symbol: "heart", name: "restingHR",
                               value: model.todayWellness?.restingHR.map { $0.formatted() }, unit: "bpm")
            }
        } information: {
            VStack(alignment: .leading, spacing: 4) {
                Text("HRV, sleep and resting heart rate are compared with your recent history.")
                if !model.measuredSignals.isSufficientlyInformed {
                    Text("Few recovery signals today, so the prescription is conservative. Connect Apple Health or wear your watch to sleep for a sharper call.")
                }
            }
        }
    }

    private var trainingLoadSection: some View {
        metricsSection("Training load", linkLabel: "Open training load details", identifier: "training-load", focus: .trainingLoad,
                       informationExpanded: $loadInformationExpanded) {
            metricLayout {
                loadMetric("Fitness", abbreviation: "CTL", value: model.latestLoad?.ctl)
                Divider()
                loadMetric("Fatigue", abbreviation: "ATL", value: model.latestLoad?.atl)
                Divider()
                loadMetric("Form", abbreviation: "TSB", value: model.latestLoad?.tsb, signed: true)
            }
        } information: {
            VStack(alignment: .leading, spacing: 4) {
                if let load = model.latestLoad {
                    Text("Intervals.icu for \(Format.day(load.day)), including planned workouts.")
                } else {
                    Text("No training load data yet.")
                }
                if let load = model.loadBeforeToday {
                    Text("Readiness uses load through \(Format.day(load.day)).")
                }
            }
        }
    }

    private func metricsSection<Content: View, Information: View>(
        _ title: LocalizedStringKey, linkLabel: LocalizedStringKey, identifier: String, focus: RecoveryView.Focus,
        informationExpanded: Binding<Bool>,
        @ViewBuilder content: () -> Content, @ViewBuilder information: @escaping () -> Information
    ) -> some View {
        let headerLayout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 0))
        return Section {
            VStack(alignment: .leading, spacing: 8) {
                headerLayout {
                    Text(title).font(.headline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 0) {
                        Button { informationExpanded.wrappedValue.toggle() } label: {
                            Image(systemName: informationExpanded.wrappedValue ? "info.circle.fill" : "info.circle")
                                .font(.body)
                                .frame(minWidth: 44, minHeight: 44)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(informationExpanded.wrappedValue ? Text("Hide information") : Text("Show information"))
                        .accessibilityIdentifier("\(identifier)-info")
                        Button { recoveryFocus = focus } label: {
                            Image(systemName: "chevron.right")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color.secondary)
                                .frame(minWidth: 44, minHeight: 44)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(Text(linkLabel))
                        .accessibilityIdentifier("\(identifier)-details")
                    }
                }
                if informationExpanded.wrappedValue {
                    information()
                        .font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button { recoveryFocus = focus } label: {
                    content()
                        .padding(.trailing, 8)
                }
                .buttonStyle(.plain)
                .accessibilityHint(Text(linkLabel))
                .accessibilityIdentifier(identifier)
            }
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 16, trailing: 8))
        }
    }

    private func metricLayout<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 0))
        return layout { content() }
            .fixedSize(horizontal: false, vertical: true)
    }

    private func recoveryMetric(_ title: LocalizedStringKey, symbol: String, name: String, value: String?, unit: LocalizedStringKey) -> some View {
        let signal = model.measuredSignals.signals.first { $0.name == name }
        let hasBaseline = signal.map { $0.verdict != .missing } ?? false
        return VStack(alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .center, spacing: 6) {
            Image(systemName: symbol)
                .font(.title).foregroundStyle(.secondary)
                .frame(minHeight: 32)
                .accessibilityHidden(true)
            metricValue(value ?? "–", unit: value == nil ? nil : unit)
            Text(title).font(.subheadline)
            Group {
                if value == nil {
                    Text("no data")
                } else if let signal, hasBaseline {
                    Text(signal.verdictText)
                } else {
                    Text("No baseline yet")
                }
            }
            .font(.caption)
            .foregroundStyle(value != nil && hasBaseline ? (signal?.verdictTint ?? .secondary) : .secondary)
        }
        .multilineTextAlignment(dynamicTypeSize.isAccessibilitySize ? .leading : .center)
        .frame(maxWidth: .infinity, alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .center)
        .accessibilityElement(children: .combine)
    }

    private func loadMetric(_ title: LocalizedStringKey, abbreviation: String, value: Double?, signed: Bool = false) -> some View {
        VStack(alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .center, spacing: 6) {
            metricValue(value.map { signed ? String(format: "%+.0f", $0) : $0.formatted(.number.precision(.fractionLength(0))) } ?? "–")
            Text(title).font(.subheadline)
            Text(verbatim: abbreviation).font(.caption).foregroundStyle(.secondary)
        }
        .multilineTextAlignment(dynamicTypeSize.isAccessibilitySize ? .leading : .center)
        .frame(maxWidth: .infinity, alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .center)
        .accessibilityElement(children: .combine)
    }

    private func metricValue(_ value: String, unit: LocalizedStringKey? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(verbatim: value).font(.largeTitle.weight(.semibold)).monospacedDigit()
            if let unit { Text(unit).font(.subheadline).foregroundStyle(.secondary) }
        }
    }

    // MARK: Event

    private func eventSection(_ event: TrainingEvent) -> some View {
        HomeSection("This week") {
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

    @ViewBuilder private var ftpReviewRow: some View {
        if let proposal = model.ftpProposal, let current = model.workingFTP {
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

    // MARK: Helpers

    private func metric(_ title: LocalizedStringKey, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold).monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
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
    HomeView().environment(PreviewData.model())
}
