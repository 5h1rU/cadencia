import SwiftUI
import Charts
import CadenciaCore

/// Shows the FTP estimate next to the working FTP with the evidence behind it. Nothing changes until the athlete says so.
struct FTPReviewView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let estimate = model.state.ftpEstimate, let current = model.workingFTP {
                    Section {
                        HStack {
                            VStack(alignment: .leading) {
                                Text("Estimate").font(.caption).foregroundStyle(.secondary)
                                Text("\(estimate.watts) W").font(.largeTitle.weight(.semibold)).monospacedDigit()
                            }
                            Spacer()
                            VStack(alignment: .trailing) {
                                Text("Working").font(.caption).foregroundStyle(.secondary)
                                Text("\(current) W").font(.largeTitle.weight(.semibold)).monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                        LabeledContent("Confidence", value: confidenceText(estimate.confidence))
                        LabeledContent("Basis", value: estimate.basis)
                        LabeledContent("Sustained efforts", value: "\(estimate.sustainedEfforts) in \(estimate.windowDays) days")
                    } footer: {
                        Text(footer(estimate))
                    }

                    Section("Power curve, last \(estimate.windowDays) days") {
                        Chart {
                            ForEach(model.state.powerCurve.filter { $0.seconds >= 60 }, id: \.seconds) { p in
                                LineMark(x: .value("Duration", Double(p.seconds) / 60), y: .value("Watts", p.watts))
                                    .interpolationMethod(.monotone)
                            }
                            RuleMark(y: .value("Working FTP", current)).foregroundStyle(.secondary).lineStyle(StrokeStyle(dash: [4]))
                                .annotation(position: .top, alignment: .trailing) { Text("FTP \(current)").font(.caption2).foregroundStyle(.secondary) }
                        }
                        .chartXScale(type: .log)
                        .chartXAxisLabel("minutes")
                        .chartYAxisLabel("W")
                        .frame(height: 180)
                    }

                    Section {
                        Button {
                            model.acceptFTP(estimate.watts)
                            dismiss()
                        } label: {
                            Label("Use \(estimate.watts) W", systemImage: "checkmark").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(estimate.confidence == .low)
                        Button("Keep \(current) W") {
                            model.keepCurrentFTP()
                            dismiss()
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .listRowBackground(Color.clear)
                } else {
                    ContentUnavailableView("No estimate yet", systemImage: "chart.line.uptrend.xyaxis",
                                           description: Text("Ride a few sustained efforts of 12 minutes or more and the estimate will appear here."))
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("FTP review")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }

    private func confidenceText(_ c: FTPEstimate.Confidence) -> String {
        switch c {
        case .low: return String(localized: "Low")
        case .moderate: return String(localized: "Moderate")
        case .high: return String(localized: "High")
        }
    }

    private func footer(_ e: FTPEstimate) -> LocalizedStringKey {
        switch e.confidence {
        case .low: return "Too few sustained efforts to trust this. Keep the working FTP; a 20-minute or ramp test would settle it."
        case .moderate: return "Several efforts point the same way. Accepting changes every zone and every target; declining keeps today as is."
        case .high: return "Repeated efforts agree. Zones and targets will move with the new value."
        }
    }
}

#Preview {
    FTPReviewView().environment(PreviewData.model())
}
