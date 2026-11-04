import SwiftUI

struct GPXImportProgressView: View {
    let fileName: String
    let status: GPXImportStatus
    let cancel: () -> Void
    @Environment(\.dynamicTypeSize) private var textSize
    @ScaledMetric(relativeTo: .body) private var cardHeight = 400.0

    private var stageTitle: LocalizedStringKey {
        switch status.stage {
        case .preparing: return "Preparing file…"
        case .reading: return "Reading GPX…"
        case .parsing: return "Reading route points…"
        case .analyzing: return "Calculating distance and elevation…"
        case .ready: return "Route ready"
        }
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.22).ignoresSafeArea()
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(spacing: 16) {
                            if !textSize.isAccessibilitySize {
                                Image(systemName: "doc.badge.arrow.up").font(.largeTitle).foregroundStyle(.tint).accessibilityHidden(true)
                            }
                            Text("Importing GPX").font(.headline)
                            if let fraction = status.fractionCompleted, let percent = status.percentage {
                                Text("\(percent)%").font(.largeTitle.bold()).monospacedDigit()
                                    .accessibilityIdentifier("gpx-import-percentage")
                                ProgressView(value: fraction)
                                    .accessibilityLabel("GPX import progress")
                                    .accessibilityValue(Text("\(percent)%"))
                            } else { ProgressView().controlSize(.large) }
                            Text(stageTitle).font(.subheadline)
                            Text(fileName).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                            if status.stage == .preparing {
                                Text("Opening the selected file before reading the route.")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        .multilineTextAlignment(.center)
                        .padding(28)
                    }
                    Divider()
                    Button(action: cancel) {
                        Text(textSize.isAccessibilitySize ? "Cancel" : "Cancel import").lineLimit(1).minimumScaleFactor(0.8)
                    }
                        .accessibilityLabel("Cancel import")
                        .buttonStyle(.bordered).controlSize(.large)
                        .padding(16)
                }
                .frame(width: min(420, max(0, geometry.size.width - 48)),
                       height: min(cardHeight, max(0, geometry.size.height - 48)))
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
                .clipShape(RoundedRectangle(cornerRadius: 24))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("gpx-import-progress")
            }
        }
    }
}

#if DEBUG
/// A stationary preview for checking both progress states and accessibility sizes in Simulator.
struct GPXImportProgressPreview: View {
    @State private var showing = true
    private var status: GPXImportStatus {
        ProcessInfo.processInfo.arguments.contains("--cadencia-preview-gpx-waiting")
            ? .preparing : GPXImportStatus(stage: .parsing, fractionCompleted: 0.42)
    }
    var body: some View {
        NavigationStack {
            Form { Button("Import route GPX") { showing = true } }
                .accessibilityHidden(showing)
                .navigationTitle("Your route")
                .overlay {
                    if showing {
                        GPXImportProgressView(fileName: "Gran-fondo-route.gpx", status: status) { showing = false }
                    }
                }
        }
    }
}
#endif
