import SwiftUI
import CadenciaCore

/// A past ride read the way the coach reads it: the verdict, the session block by block, and the
/// numbers Intervals computed from the file. Reached from Today's "Last session" card.
struct RideDebriefView: View {
    @Environment(AppModel.self) private var model
    let rideID: UUID

    var body: some View {
        if let ride = model.ride(id: rideID) {
            List {
                Section {
                    RideStatsRow(ride: ride, ftp: model.workingFTP ?? 200)
                } header: {
                    Text(ride.startedAt, format: .dateTime.weekday(.wide).day().month(.wide).hour().minute())
                }
                DebriefSections(ride: ride)
            }
            .listStyle(.insetGrouped)
            .navigationTitle(ride.workout.name)
            .navigationBarTitleDisplayMode(.inline)
        } else {
            ContentUnavailableView("Ride not found", systemImage: "bicycle")
        }
    }
}

/// Time, power, load and heart rate for one ride, from our own recording.
struct RideStatsRow: View {
    let ride: RideRecording
    let ftp: Int

    var body: some View {
        HStack(spacing: 16) {
            stat("Time", Format.clock(ride.duration))
            stat("Avg", Format.watts(ride.averageWatts))
            stat("NP", Format.watts(ride.normalizedWatts))
            stat("Load", ride.trainingLoad(ftp: ftp).map { "\($0)" } ?? "–")
            stat("Avg HR", ride.averageHeartRate.map { "\($0)" } ?? "–")
        }
        .padding(.vertical, 4)
    }

    private func stat(_ title: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline.monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The debrief itself as List sections: the coach's verdict and prose, then the blocks, then Intervals'
/// numbers, then anything to watch. Shows the waiting and failed states while the debrief is on its way.
struct DebriefSections: View {
    @Environment(AppModel.self) private var model
    let ride: RideRecording

    private var status: AppModel.DebriefStatus? { model.debriefStatus[ride.id] }
    private var uploaded: Bool { model.state.ledger.entry(for: ride.id)?.state == .confirmed }
    private var ftp: Int { model.workingFTP ?? 200 }

    private var executed: [RideCommentary.BlockStats] {
        ride.workout.steps.indices.map { RideCommentary.BlockStats.compute(index: $0, workout: ride.workout, ftp: ftp, samples: ride.samples) }
    }

    var body: some View {
        Section {
            if let report = ride.debrief {
                VStack(alignment: .leading, spacing: 10) {
                    GradeBadge(grade: report.grade)
                    Text(report.headline).font(.title3.weight(.semibold))
                }
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
        } header: {
            Label("Coach debrief", systemImage: "sparkles")
        } footer: {
            if let report = ride.debrief {
                Text("Written by \(report.model) from this recording and the Intervals analysis.")
            }
        }

        if let report = ride.debrief, !report.blocks.isEmpty {
            Section("Blocks") {
                ForEach(report.blocks) { verdict in
                    let stats = executed.indices.contains(verdict.index) ? executed[verdict.index] : nil
                    BlockVerdictRow(verdict: verdict, stats: stats)
                }
            }
        }

        if let analysis = ride.analysis {
            Section {
                if !analysis.powerZoneTimes.isEmpty {
                    ZoneTimeBar(title: "Power zones", slices: analysis.powerZoneTimes.map { (zone: $0.zone, seconds: $0.seconds) })
                }
                if analysis.hrZoneTimes.contains(where: { $0 > 0 }) {
                    ZoneTimeBar(title: "Heart-rate zones", slices: analysis.hrZoneTimes.enumerated().map { (zone: "Z\($0.offset + 1)", seconds: $0.element) })
                }
                MetricsGrid(analysis: analysis)
            } header: {
                Text("From Intervals")
            } footer: {
                Text("Decoupling is how much heart rate drifted for the same power between the two halves; efficiency factor is normalized power per heartbeat; HR recovery is the drop in the first minute after the hardest effort.")
            }
        }

        if let report = ride.debrief, !report.flags.isEmpty {
            Section("Watch") {
                ForEach(report.flags, id: \.self) { flag in
                    Label(flag, systemImage: "eye").font(.subheadline)
                }
            }
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

/// "Nailed it" / "Solid" / "Partial" / "Off plan" as a tinted capsule.
struct GradeBadge: View {
    let grade: RideDebrief.Report.Grade

    var body: some View {
        Text(Self.title(grade))
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Self.color(grade).opacity(0.18), in: Capsule())
            .foregroundStyle(Self.color(grade))
    }

    static func title(_ grade: RideDebrief.Report.Grade) -> LocalizedStringKey {
        switch grade {
        case .excellent: return "Nailed it"
        case .good: return "Solid"
        case .partial: return "Partial"
        case .off: return "Off plan"
        }
    }

    static func color(_ grade: RideDebrief.Report.Grade) -> Color {
        switch grade {
        case .excellent: return .green
        case .good: return .blue
        case .partial: return .orange
        case .off: return .red
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
                    Text(stats?.name ?? "Block \(verdict.index + 1)")
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

/// Time in zones as one stacked bar plus a legend of the zones that got real time.
struct ZoneTimeBar: View {
    let title: LocalizedStringKey
    let slices: [(zone: String, seconds: Int)]

    private var total: Int { max(slices.reduce(0) { $0 + $1.seconds }, 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            GeometryReader { geo in
                HStack(spacing: 1) {
                    ForEach(Array(slices.enumerated()), id: \.offset) { i, slice in
                        let width = geo.size.width * CGFloat(slice.seconds) / CGFloat(total)
                        Rectangle().fill(Self.color(index: i)).frame(width: max(width, slice.seconds > 0 ? 2 : 0))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .frame(height: 14)
            HStack(spacing: 12) {
                ForEach(Array(slices.enumerated()), id: \.offset) { i, slice in
                    if slice.seconds >= 60 {
                        HStack(spacing: 4) {
                            Circle().fill(Self.color(index: i)).frame(width: 8, height: 8)
                            Text("\(slice.zone) \(Format.minutes(TimeInterval(slice.seconds)))").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    static func color(index: Int) -> Color {
        [Color.gray, .blue, .green, .yellow, .orange, .red, .purple][min(index, 6)]
    }
}

/// The headline numbers Intervals computed, three to a row.
struct MetricsGrid: View {
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
        LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], spacing: 12) {
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

#Preview("Debriefed") {
    let ride = PreviewData.debriefedRide
    NavigationStack { RideDebriefView(rideID: ride.id) }.environment(PreviewData.model(rides: [ride]))
}
