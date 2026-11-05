import SwiftUI
import CadenciaCore

/// A past ride read the way the coach reads it: the debrief, the session block by block, and the
/// numbers Intervals computed from the file. Reached from Today's "Last session" card.
struct RideDebriefView: View {
    @Environment(AppModel.self) private var model
    let rideID: UUID
    /// The newest copy the screen has shown. When a memory warning drops the ride from the cache, the screen
    /// keeps it while the file is read back, so the scroll position, the open sections and a debrief in
    /// progress stay put.
    @State private var shownRide: RideRecording?
    /// The ride whose file could not be read. Until a load says so, a ride missing from the cache is
    /// still loading, not "not found".
    @State private var unreadableRideID: UUID?

    var body: some View {
        if let ride = model.cachedRide(id: rideID) ?? shownRide.flatMap({ $0.id == rideID ? $0 : nil }) {
            List {
                Section {
                    RideStatsRow(ride: ride, ftp: ride.ftpUsed ?? model.workingFTP ?? 200)
                } header: {
                    Text(ride.startedAt, format: .dateTime.weekday(.wide).day().month(.wide).hour().minute())
                }
                if ride.sourceActivity != nil || ride.recordedRoute != nil { RecordedRideRouteSections(ride: ride) }
                DebriefSections(ride: ride)
            }
            .listStyle(.insetGrouped)
            .navigationTitle(ride.workout.name)
            .navigationBarTitleDisplayMode(.inline)
            .task(id: rideID) {
                if RideDebrief.requiresRefresh(ride) { await model.debriefRide(rideID) }
                else { await model.syncDebriefNote(for: rideID) }
            }
            .task(id: rideID) { await model.loadRideRoute(rideID) }
            // Seeds the copy on screen, and reads the ride back off the main actor once a purge drops it.
            .task(id: model.cachedRide(id: rideID) == nil) {
                if let loaded = await model.loadRide(id: rideID) { shownRide = loaded }
            }
            // Each newer copy becomes the fallback, so a purge never shows older data than the screen already showed.
            .onChange(of: model.cachedRide(id: rideID)) { _, latest in
                if let latest { shownRide = latest }
            }
        } else {
            // An empty list keeps the screen's grouped background while the file is decoded off the main actor.
            List {}
                .listStyle(.insetGrouped)
                .overlay {
                    if unreadableRideID == rideID {
                        ContentUnavailableView("Ride not found", systemImage: "bicycle")
                    } else {
                        ProgressView()
                    }
                }
                .navigationBarTitleDisplayMode(.inline)
                .task(id: rideID) {
                    if await model.loadRide(id: rideID) == nil { unreadableRideID = rideID }
                }
        }
    }
}

/// Time, power, load and heart rate for one ride, from our own recording.
struct RideStatsRow: View {
    let ride: RideRecording
    let ftp: Int
    private var analysis: ActivityDetail? { ride.analysis?.analyzed == true ? ride.analysis : nil }

    var body: some View {
        HStack(spacing: 16) {
            stat("Time", analysis.map { Format.clock($0.movingTime) } ?? "–")
            stat("Avg", Format.watts(analysis?.averageWatts))
            stat("NP", Format.watts(analysis?.normalizedWatts))
            stat("Load", analysis?.trainingLoad.map { "\($0)" } ?? "–")
            stat("Avg HR", analysis?.averageHR.map { "\($0)" } ?? "–")
        }
        .padding(.vertical, 4)
    }

    private func stat(_ title: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline.monospacedDigit()).lineLimit(1).minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The debrief itself as List sections: the coach's collapsible prose, then the blocks, then Intervals'
/// numbers, then anything to watch. Shows the waiting and failed states while the debrief is on its way.
struct DebriefSections: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var isDebriefExpanded = false
    let ride: RideRecording

    private var status: AppModel.DebriefStatus? { model.debriefStatus[ride.id] }
    /// Where the debrief stands while there is nothing to read yet; the collapsed header shows it too.
    private var pendingStatus: AppModel.DebriefStatus? { visibleNote == nil && visibleReport == nil ? status : nil }
    private var isSyncingNote: Bool { model.syncingDebriefNotes.contains(ride.id) }
    private var uploaded: Bool { ride.sourceActivity != nil || model.state.ledger.entry(for: ride.id)?.state == .confirmed }
    private var ftp: Int { ride.ftpUsed ?? model.workingFTP ?? 200 }

    private var visibleReport: RideDebrief.Report? { RideDebrief.requiresRefresh(ride) ? nil : ride.debrief }
    private var visibleNote: IntervalsActivityNote? { RideDebrief.requiresRefresh(ride) ? nil : ride.debriefNote }

    var body: some View {
        InfoSection(hasInformation: visibleNote != nil || visibleReport != nil, stacksHeaderAtAccessibilitySizes: true) {
            if isDebriefExpanded {
                debriefContent
            }
        } header: {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                    isDebriefExpanded.toggle()
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if dynamicTypeSize.isAccessibilitySize {
                        Text("Coach debrief")
                    } else {
                        Label("Coach debrief", systemImage: "sparkles")
                    }
                    Spacer(minLength: 8)
                    // Centered on the chevron, which keeps its baseline alignment with the title.
                    HStack(spacing: 8) {
                        if !isDebriefExpanded { pendingIndicator }
                        Image(systemName: isDebriefExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(headerAccessibilityValue)
            .accessibilityIdentifier("coach-debrief-toggle")
        } information: {
            if visibleNote != nil {
                Text("This is the coach note saved with your activity in Intervals.icu.")
            } else if let report = visibleReport {
                Text("Written by \(report.model) from the Intervals.icu analysis and your planned workout.")
            }
        }

        if visibleNote == nil, let report = visibleReport, !report.blocks.isEmpty {
            Section("Blocks") {
                ForEach(report.blocks) { verdict in
                    BlockVerdictRow(verdict: verdict, stats: nil)
                }
            }
        }

        if let analysis = ride.analysis {
            IntervalsAnalysisSections(analysis: analysis)
        }

        if visibleNote == nil, let report = visibleReport, !report.flags.isEmpty {
            Section("Watch") {
                ForEach(report.flags, id: \.self) { flag in
                    Label(flag, systemImage: "eye").font(.subheadline)
                }
            }
        }
    }

    @ViewBuilder private var debriefContent: some View {
        if let note = visibleNote {
            Text(note.debriefText).lineSpacing(3)
        } else if let report = visibleReport {
            Text(report.headline).font(.title3.weight(.semibold))
                .padding(.vertical, 4)
            paragraph("What it built", report.benefit)
            paragraph("How you rode it", report.execution)
            paragraph("What your body said", report.physiology)
            paragraph("Next", report.next)
        } else {
            switch status {
            case .waitingForIntervals:
                progressRow("Reading your session…", detail: "Waiting for Intervals to process the file.")
            case .reading:
                progressRow("Reading your session…", detail: "The coach has the numbers and is writing.")
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.secondary)
                Button("Ask again") { Task { await model.debriefRide(ride.id) } }
            case nil:
                if uploaded {
                    Button("Ask the coach") { Task { await model.debriefRide(ride.id) } }
                } else {
                    Text("The debrief arrives once the ride is in Intervals.").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        if let message = model.debriefNoteErrors[ride.id] {
            Label(message, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.secondary)
            // Busy while any sync of this note runs, including the automatic ones.
            Button {
                Task { await model.syncDebriefNote(for: ride.id) }
            } label: {
                HStack {
                    Text("Retry note sync")
                    Spacer()
                    if isSyncingNote { ProgressView() }
                }
            }
            .disabled(isSyncingNote)
        } else if visibleNote != nil {
            Label("Saved in Intervals.icu Notes", systemImage: "checkmark.icloud").font(.footnote).foregroundStyle(.secondary)
        }
    }

    /// On the collapsed header: the debrief is on its way, or it failed. The details are inside.
    @ViewBuilder private var pendingIndicator: some View {
        switch pendingStatus {
        case .waitingForIntervals, .reading:
            ProgressView().controlSize(.small).accessibilityHidden(true)
        case .failed:
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.secondary).accessibilityHidden(true)
        case nil:
            EmptyView()
        }
    }

    private var headerAccessibilityValue: String {
        let expansion = isDebriefExpanded ? String(localized: "Expanded") : String(localized: "Collapsed")
        guard !isDebriefExpanded else { return expansion }
        switch pendingStatus {
        case .waitingForIntervals, .reading: return "\(expansion), \(String(localized: "Reading your session…"))"
        case .failed(let message): return "\(expansion), \(message)"
        case nil: return expansion
        }
    }

    private func paragraph(_ title: LocalizedStringKey, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            Text(text).font(.subheadline)
        }
        .padding(.vertical, 2)
    }

    private func progressRow(_ title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
        HStack(spacing: 12) {
            ProgressView()
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

/// One block: the coach's verdict, what was asked, what was ridden, and the share of time in zone.
struct BlockVerdictRow: View {
    let verdict: RideDebrief.Report.BlockVerdict
    let stats: RideCommentary.BlockStats?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).foregroundStyle(color).font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(stats?.name ?? String(localized: "Block \(verdict.index + 1)"))
                    Spacer()
                    if let pct = stats?.inZonePercent {
                        Text("\(pct) % in zone").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 4) {
                    Text(title).foregroundStyle(color)
                    if let stats {
                        Text("·")
                        Text("\(Format.watts(stats.targetWatts)) → \(Format.watts(stats.avgWatts)) · \(Format.minutes(TimeInterval(stats.seconds)))")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                if !verdict.note.isEmpty {
                    Text(verdict.note).font(.footnote)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var title: LocalizedStringKey {
        switch verdict.verdict {
        case .hit: return "On target"
        case .over: return "Over target"
        case .under: return "Under target"
        case .short: return "Cut short"
        }
    }

    private var symbol: String {
        switch verdict.verdict {
        case .hit: return "checkmark.circle.fill"
        case .over: return "arrow.up.circle.fill"
        case .under: return "arrow.down.circle.fill"
        case .short: return "xmark.circle.fill"
        }
    }

    private var color: Color {
        switch verdict.verdict {
        case .hit: return .green
        case .over: return .orange
        case .under: return .blue
        case .short: return .red
        }
    }
}

/// Presents the provider's activity zones without imposing a local zone scheme or summing SS.
struct IntervalsAnalysisSections: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isMetricsExpanded = false
    let analysis: ActivityDetail

    private var hasPowerZones: Bool { !analysis.powerZoneTimes.isEmpty }
    private var hasHRZones: Bool { analysis.hrZoneTimes.contains(where: { $0 > 0 }) }

    private var metricsSummary: String {
        var values: [String] = []
        if let load = analysis.trainingLoad { values.append("\(String(localized: "Load")) \(load)") }
        if let intensity = analysis.intensityFactor { values.append("\(String(localized: "Intensity")) \(String(format: "%.2f", intensity))") }
        if let watts = analysis.normalizedWatts { values.append("\(String(localized: "NP")) \(Format.watts(watts))") }
        return values.joined(separator: " · ")
    }

    var body: some View {
        if hasPowerZones {
            Section {
                zoneHeading("Power zones")
                zoneRows(analysis.powerZoneTimes, prefix: "power-zone")
            } header: {
                Text("From Intervals")
            }
        }
        if hasHRZones {
            Section {
                zoneHeading("Heart-rate zones")
                // Intervals returns seconds in zone order, starting at Z1. Keep every slot,
                // including zero-time zones, and the actual number of zones in this activity.
                zoneRows(analysis.hrZoneTimes.enumerated().map {
                    ActivityDetail.ZoneTime(zone: "Z\($0.offset + 1)", seconds: $0.element)
                }, prefix: "heart-rate-zone")
            } header: {
                if !hasPowerZones { Text("From Intervals") }
            }
        }
        InfoSection(stacksHeaderAtAccessibilitySizes: true) {
            if isMetricsExpanded { MetricsGrid(analysis: analysis) }
        } header: {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                    isMetricsExpanded.toggle()
                }
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Ride metrics").font(.headline)
                        if !isMetricsExpanded && !metricsSummary.isEmpty {
                            Text(metricsSummary).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: isMetricsExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .padding(.vertical, 8)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isMetricsExpanded ? Text("Expanded") : Text("Collapsed"))
            .accessibilityIdentifier("ride-metrics-toggle")
        } information: {
            Text("Decoupling is how much heart rate drifted for the same power between the two halves; efficiency factor is normalized power per heartbeat; HR recovery is the drop in the first minute after the hardest effort.")
        }
    }

    private func zoneHeading(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.headline)
            .accessibilityAddTraits(.isHeader)
            .listRowSeparator(.hidden, edges: .bottom)
    }

    @ViewBuilder private func zoneRows(_ zones: [ActivityDetail.ZoneTime], prefix: String) -> some View {
        ForEach(Array(zones.enumerated()), id: \.offset) { _, zone in
            IntervalsZoneTimeRow(zone: zone)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                .accessibilityIdentifier("\(prefix)-\(zone.zone)")
        }
    }
}

/// One provider zone and one duration: neither competes for a narrow legend column.
private struct IntervalsZoneTimeRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.locale) private var locale
    let zone: ActivityDetail.ZoneTime

    private var isSweetSpot: Bool { zone.zone.uppercased() == "SS" }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Capsule().fill(color)
                .frame(width: 6, height: 24)
                .padding(.top, 2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                rowLayout {
                    Text(verbatim: zone.zone).font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(Format.zoneTime(zone.seconds, locale: locale))
                        .font(.body.weight(.semibold).monospacedDigit())
                        .fixedSize()
                }
                if isSweetSpot {
                    Text("Sweet Spot · overlaps power zones")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var rowLayout: AnyLayout {
        if dynamicTypeSize.isAccessibilitySize {
            AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
        } else {
            AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 12))
        }
    }

    // Resolve by provider ID, not array offset: absent zones must not shift colors.
    private var color: Color {
        switch zone.zone.uppercased() {
        case "Z1": return .gray
        case "Z2": return .blue
        case "Z3": return .green
        case "Z4": return .yellow
        case "Z5": return .orange
        case "Z6": return .red
        case "Z7": return .purple
        case "SS": return .purple
        default: return .gray
        }
    }
}

/// The numbers Intervals computed, with a single column at accessibility text sizes.
struct MetricsGrid: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let analysis: ActivityDetail

    private var metrics: [(LocalizedStringKey, String)] {
        var rows: [(LocalizedStringKey, String)] = []
        if let v = analysis.trainingLoad { rows.append(("Load", "\(v)")) }
        if let v = analysis.intensityFactor { rows.append(("Intensity", String(format: "%.2f", v))) }
        if let v = analysis.normalizedWatts { rows.append(("NP", Format.watts(v))) }
        if let v = analysis.averageWatts { rows.append(("Avg power", Format.watts(v))) }
        if let v = analysis.averageHR { rows.append(("Avg HR", "\(v) bpm")) }
        if let v = analysis.maxHR { rows.append(("Max HR", "\(v) bpm")) }
        if let v = analysis.efficiencyFactor { rows.append(("Efficiency", String(format: "%.2f", v))) }
        if let v = analysis.decoupling { rows.append(("Decoupling", String(format: "%.1f %%", v))) }
        if let v = analysis.hrRecovery?.drop { rows.append(("HR recovery", "\(v) bpm")) }
        if let v = analysis.variabilityIndex { rows.append(("Variability", String(format: "%.2f", v))) }
        if let v = analysis.kilojoules { rows.append(("Work", "\(v) kJ")) }
        if let v = analysis.averageCadence { rows.append(("Cadence", "\(v) rpm")) }
        if let v = analysis.estimatedFTP { rows.append(("eFTP", Format.watts(v))) }
        if let v = analysis.compliance { rows.append(("Compliance", "\(Int(v.rounded())) %")) }
        if let c = analysis.ctl, let a = analysis.atl { rows.append(("Form", String(format: "%.0f / %.0f / %+.0f", c, a, c - a))) }
        return rows
    }

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: dynamicTypeSize.isAccessibilitySize ? 1 : 2), alignment: .leading, spacing: 16) {
            ForEach(Array(metrics.enumerated()), id: \.offset) { _, m in
                VStack(alignment: .leading, spacing: 2) {
                    Text(m.0).font(.caption).foregroundStyle(.secondary)
                    Text(m.1).font(.subheadline.weight(.semibold).monospacedDigit())
                }
            }
        }
        .padding(.vertical, 4)
    }
}

#if DEBUG
/// Isolated layout preview; it never starts an account sync or writes a ride.
struct RideZoneLayoutPreview: View {
    var body: some View {
        NavigationStack {
            List { IntervalsAnalysisSections(analysis: PreviewData.zoneLayoutAnalysis) }
                .listStyle(.insetGrouped)
                .navigationTitle(PreviewData.zoneLayoutAnalysis.name)
                .navigationBarTitleDisplayMode(.inline)
        }
        .preferredColorScheme(ProcessInfo.processInfo.arguments.contains("--cadencia-preview-light") ? .light : .dark)
    }
}
#endif

#Preview("Debriefed") {
    let ride = PreviewData.debriefedRide
    NavigationStack { RideDebriefView(rideID: ride.id) }.environment(PreviewData.model(rides: [ride]))
}
