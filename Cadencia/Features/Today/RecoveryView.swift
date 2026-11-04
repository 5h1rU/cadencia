import SwiftUI
import Charts
import CadenciaCore

/// Recovery evidence: HRV against the personal typical range, fitness/fatigue/form, and each signal's verdict.
struct RecoveryView: View {
    enum Focus: Hashable { case recovery, trainingLoad }

    var focus: Focus = .recovery
    @Environment(AppModel.self) private var model
    @State private var window = 28

    private var days: [WellnessDay] {
        let from = model.today.adding(days: -window)
        return model.state.wellness.filter { $0.day >= from }
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                InfoSection {
                    Picker("Window", selection: $window) {
                        Text("2 weeks").tag(14)
                        Text("4 weeks").tag(28)
                        Text("3 months").tag(90)
                    }
                    .pickerStyle(.segmented)
                    .listRowSeparator(.hidden)
                    hrvChart
                } header: {
                    Text("HRV")
                } information: {
                    if let s = model.readiness?.signals.first(where: { $0.name == "hrv" }), let range = s.baseline {
                        Text("Your typical range over the last 28 days is \(Int(range.lowerBound))–\(Int(range.upperBound)) ms. One low morning means little; a run of them does.")
                    } else {
                        Text("Seven mornings of HRV are needed before a typical range can be computed.")
                    }
                }
                .id(Focus.recovery)

                InfoSection(hasInformation: model.latestLoad != nil || model.loadBeforeToday != nil) {
                    loadChart
                    if let w = model.latestLoad {
                        LabeledContent("Fitness (CTL)", value: w.ctl.map { String(format: "%.0f", $0) } ?? "–")
                        LabeledContent("Fatigue (ATL)", value: w.atl.map { String(format: "%.0f", $0) } ?? "–")
                        LabeledContent("Form (TSB)", value: w.tsb.map { String(format: "%+.0f", $0) } ?? "–")
                    }
                } header: {
                    Text("Training load")
                } information: {
                    VStack(alignment: .leading, spacing: 4) {
                        if let load = model.latestLoad {
                            Text("Intervals.icu for \(Format.day(load.day)), including planned workouts.")
                        }
                        if let load = model.loadBeforeToday {
                            Text("Readiness uses load through \(Format.day(load.day)).")
                        }
                    }
                }
                .id(Focus.trainingLoad)

                if let r = model.readiness {
                    Section {
                        ForEach(r.signals) { s in
                            LabeledContent {
                                VStack(alignment: .trailing) {
                                    Text(s.valueText).monospacedDigit()
                                    Text(s.verdictText).font(.caption).foregroundStyle(s.verdictTint)
                                }
                            } label: {
                                if s.name == "form" {
                                    Text("Form before today")
                                } else if s.name == "fatigue" {
                                    Text("Fatigue before today")
                                } else {
                                    Text(s.title)
                                }
                            }
                        }
                        if !r.missingData.isEmpty {
                            Text("Missing today: \(r.missingData.joined(separator: ", ")). Without them the call is more conservative.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("Today's verdict: \(Text(r.level.title)) · \(r.score)/100")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Recovery")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                if focus == .trainingLoad { proxy.scrollTo(Focus.trainingLoad, anchor: .top) }
            }
        }
    }

    private var hrvChart: some View {
        let range = model.readiness?.signals.first { $0.name == "hrv" }?.baseline
        return Chart {
            if let range {
                RectangleMark(yStart: .value("Low", range.lowerBound), yEnd: .value("High", range.upperBound))
                    .foregroundStyle(.green.opacity(0.12))
            }
            ForEach(days.filter { $0.hrvMs != nil }) { d in
                LineMark(x: .value("Day", d.day.date()), y: .value("HRV", d.hrvMs!))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(.teal)
                PointMark(x: .value("Day", d.day.date()), y: .value("HRV", d.hrvMs!))
                    .symbolSize(d.day == model.today ? 60 : 12)
                    .foregroundStyle(.teal)
            }
        }
        .chartYAxisLabel("ms")
        .chartXAxis { AxisMarks(values: .stride(by: .day, count: max(window / 4, 1))) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.day().month(.abbreviated)) } }
        .frame(height: 180)
    }

    private var loadChart: some View {
        Chart {
            ForEach(days.filter { $0.ctl != nil }) { d in
                LineMark(x: .value("Day", d.day.date()), y: .value("CTL", d.ctl!), series: .value("Series", "Fitness"))
                    .foregroundStyle(.blue)
            }
            ForEach(days.filter { $0.atl != nil }) { d in
                LineMark(x: .value("Day", d.day.date()), y: .value("ATL", d.atl!), series: .value("Series", "Fatigue"))
                    .foregroundStyle(.pink)
            }
        }
        .chartForegroundStyleScale(["Fitness": Color.blue, "Fatigue": Color.pink])
        .chartLegend(position: .bottom)
        .frame(height: 160)
    }
}

#Preview {
    NavigationStack { RecoveryView() }.environment(PreviewData.model())
}
