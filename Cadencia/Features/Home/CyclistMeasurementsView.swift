import SwiftUI
import CadenciaCore

enum CyclistMeasureText {
    static func weight(_ kg: Double, metric: Bool) -> String {
        let value = (metric ? kg : kg / 0.45359237).formatted(.number.precision(.fractionLength(0...1)))
        return metric ? "\(value) kg" : "\(value) lb"
    }
    static func height(_ cm: Double, metric: Bool) -> String {
        if metric { return "\(cm.formatted(.number.precision(.fractionLength(0...1)))) cm" }
        let inches = Int((cm / 2.54).rounded())
        return "\(inches / 12) ft \(inches % 12) in"
    }
    static func relativePower(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(2)))) W/kg"
    }
}

struct CyclistMeasurementsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss
    var proposed: PlanConsultation.ProfileUpdate?
    @State private var weight = ""
    @State private var height = ""
    @State private var ftp = ""
    @State private var metric = true
    @State private var initialized = false
    @State private var busy = false
    @State private var importing = false
    @State private var notice: String?

    var body: some View {
        Form {
            Section {
                Picker("Units", selection: $metric) {
                    Text("Metric").tag(true)
                    Text("Imperial").tag(false)
                }
                .onChange(of: metric) { _, new in convertUnits(toMetric: new) }
                LabeledContent("Weight") {
                    HStack {
                        TextField("Not added", text: $weight)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .accessibilityLabel("Weight")
                        Text(metric ? "kg" : "lb").foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Height") {
                    HStack {
                        TextField("Not added", text: $height)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .accessibilityLabel("Height")
                        Text(metric ? "cm" : "in").foregroundStyle(.secondary)
                    }
                }
                LabeledContent("FTP") {
                    HStack {
                        TextField("Not set", text: $ftp)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .accessibilityLabel("FTP")
                        Text("W").foregroundStyle(.secondary)
                    }
                }
                if let value = CyclistMeasurements.wattsPerKg(ftp: parsedFTP, weightKg: parsedWeight) {
                    LabeledContent("Relative power", value: CyclistMeasureText.relativePower(value))
                }
            } header: {
                Text(proposed?.isEmpty == false ? "Confirm what the coach heard" : "Measurements")
            } footer: {
                Text("These measurements are saved to your cyclist profile. You can leave any unknown value blank.")
            }
            if model.state.profileWeight != nil || model.state.cyclistMeasurements?.height != nil {
                Section("Sources") {
                    if let value = model.state.profileWeight { source("Weight", value) }
                    if let value = model.state.cyclistMeasurements?.height { source("Height", value) }
                }
            }
            if model.state.profileWeightPendingSync != nil {
                Text("Weight saved on this phone. Intervals.icu sync is pending.")
                    .foregroundStyle(.secondary)
            }
            Section {
                // Health may ask for access first; the row keeps its label and shows a spinner while it reads.
                Button {
                    Task { await importHealth() }
                } label: {
                    LabeledContent {
                        if importing { ProgressView() }
                    } label: {
                        Label("Import from Apple Health", systemImage: "heart.text.square")
                    }
                }
                .disabled(busy || !HealthKitService.isAvailable)
                if let notice { Text(verbatim: notice).foregroundStyle(.secondary) }
            }
            Section {
                Button("Save profile details") {
                    Task { await save() }
                }
                .disabled(busy || !valid || update.isEmpty)
            }
        }
        .navigationTitle("Cyclist profile")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard !initialized else { return }
            metric = model.state.settings.unitsMetric
            fill(proposed)
            initialized = true
        }
    }

    private func source(_ label: LocalizedStringKey, _ value: CyclistMeasurements.Measurement) -> some View {
        LabeledContent(label) {
            VStack(alignment: .trailing) {
                switch value.source {
                case .appleHealth: Text("Apple Health")
                case .athlete: Text("Confirmed by you")
                case .intervals: Text("Intervals.icu")
                }
                if value.measuredAt != .distantPast { Text(value.measuredAt, style: .date) }
            }
        }
    }

    private var parsedWeight: Double? { parse(weight).map { metric ? $0 : $0 * 0.45359237 } }
    private var parsedHeight: Double? { parse(height).map { metric ? $0 : $0 * 2.54 } }
    private var parsedFTP: Int? { Int(ftp.trimmingCharacters(in: .whitespacesAndNewlines)) }
    private var update: PlanConsultation.ProfileUpdate {
        .init(weightKg: changed(parsedWeight, from: model.state.weightKg, proposed: proposed?.weightKg),
              heightCm: changed(parsedHeight, from: model.state.heightCm, proposed: proposed?.heightCm),
              ftp: parsedFTP != model.workingFTP || proposed?.ftp != nil ? parsedFTP : nil)
    }
    private var valid: Bool {
        if !weight.isEmpty && parsedWeight == nil || !height.isEmpty && parsedHeight == nil || !ftp.isEmpty && parsedFTP == nil { return false }
        do { try PlanConsultation.ProfileUpdate(weightKg: parsedWeight, heightCm: parsedHeight, ftp: parsedFTP).validate(); return true }
        catch { return false }
    }

    private func changed(_ value: Double?, from original: Double?, proposed: Double?) -> Double? {
        guard let value else { return nil }
        if proposed != nil || original.map({ abs(value - $0) >= 0.1 }) ?? true { return value }
        return nil
    }

    private func parse(_ text: String) -> Double? {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        return try? FloatingPointFormatStyle<Double>.number.locale(locale).parseStrategy.parse(raw)
    }
    private func number(_ value: Double) -> String {
        value.formatted(.number.locale(locale).precision(.fractionLength(0...1)).grouping(.never))
    }
    private func fill(_ proposed: PlanConsultation.ProfileUpdate? = nil) {
        weight = (proposed?.weightKg ?? model.state.weightKg).map { number(metric ? $0 : $0 / 0.45359237) } ?? ""
        height = (proposed?.heightCm ?? model.state.heightCm).map { number(metric ? $0 : $0 / 2.54) } ?? ""
        ftp = (proposed?.ftp ?? model.workingFTP).map(String.init) ?? ""
    }
    private func convertUnits(toMetric: Bool) {
        guard initialized else { return }
        if let value = parse(weight) { weight = number(toMetric ? value * 0.45359237 : value / 0.45359237) }
        if let value = parse(height) { height = number(toMetric ? value * 2.54 : value / 2.54) }
    }
    private func save() async {
        guard valid, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            try await model.saveCyclistProfile(update)
            dismiss()
        } catch { notice = String(localized: "Check the measurements and units, then try again.") }
    }
    private func importHealth() async {
        guard !busy else { return }
        busy = true
        importing = true
        defer { busy = false; importing = false }
        do {
            let updated = try await model.importCyclistMeasurements()
            fill(proposed)
            if !updated {
                notice = String(localized: "No newer weight or height was available in Apple Health.")
            } else { notice = String(localized: "Profile updated from Apple Health.") }
        } catch { notice = String(localized: "Couldn’t read measurements from Apple Health.") }
    }
}
