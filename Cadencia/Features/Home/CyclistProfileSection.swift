import SwiftUI
import CadenciaCore

struct CyclistProfileSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HomeSection("Your cyclist profile") {
            NavigationLink {
                CyclistProfileView()
            } label: {
                Group {
                    if model.cyclistProfileBusy {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Reading your riding history…")
                                .foregroundStyle(.secondary)
                        }
                    } else if model.cyclistProfileError != nil {
                        Text("Profile needs attention")
                            .foregroundStyle(.orange)
                    } else {
                        Text("View your full profile")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.subheadline)
                .padding(.vertical, 6)
            }
            .accessibilityIdentifier("cyclist-profile-link")
        }
    }
}

struct CyclistProfileView: View {
    var body: some View {
        ScrollView {
            CyclistProfileContent()
                .padding(.horizontal, 16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Your cyclist profile")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct CyclistProfileContent: View {
    @Environment(AppModel.self) private var model
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            NavigationLink {
                CyclistMeasurementsView()
            } label: {
                Label("Profile details", systemImage: "person.crop.circle")
            }
            if let profile = model.state.cyclistProfile {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: symbol(profile.riderType))
                        .font(.title2).foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title(profile.riderType)).font(.title3.weight(.semibold))
                        Text(confidence(profile.confidence)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(profile.headline).font(.subheadline.weight(.semibold))
                Text(profile.summary).font(.subheadline)

                DisclosureGroup("What your history shows", isExpanded: $expanded) {
                    VStack(alignment: .leading, spacing: 16) {
                        insights("Where you shine", items: profile.strengths, symbol: "bolt.fill")
                        insights("Room to grow", items: profile.development, symbol: "arrow.up.right")
                        insights("The evidence", items: profile.evidence, symbol: "chart.bar.xaxis")
                        insights("Still to learn", items: profile.caveats, symbol: "info.circle")
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(profile.rideCount) rides · \(Format.day(profile.oldest)) – \(Format.day(profile.newest))")
                            Text("Generated \(profile.generatedAt.formatted(date: .abbreviated, time: .omitted))")
                            Text(verbatim: profile.model)
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.top, 12)
                }
                .font(.subheadline)
            } else {
                Text("Discover the rider behind your rides")
                    .font(.title3.weight(.semibold))
                Text("Your coach looks at six months of Intervals.icu rides, climbing, power and feedback to explain your strengths and the kind of cyclist you're becoming.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }

            if model.cyclistProfileBusy {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Reading your riding history…").font(.subheadline).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            if let error = model.cyclistProfileError {
                Text(error).font(.footnote).foregroundStyle(.orange)
            }

            Button {
                Task { await model.generateCyclistProfile() }
            } label: {
                Label(model.state.cyclistProfile == nil ? "Generate my profile" : "Update my profile", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(model.cyclistProfileBusy || !model.isSignedIn || !model.aiCoachAvailable)

            if !model.isSignedIn {
                Text("Connect Intervals.icu in Settings to build your cyclist profile.").font(.caption).foregroundStyle(.secondary)
            } else if !model.aiCoachAvailable {
                Text("Connect ChatGPT (or an API key) in Settings → Coach first.").font(.caption).foregroundStyle(.secondary)
            }
            Text("Generated once automatically. Updated only when you ask.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func insights(_ title: LocalizedStringKey, items: [String], symbol: String) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label(title, systemImage: symbol).font(.subheadline.weight(.semibold))
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in Text(item).font(.subheadline) }
            }
        }
    }

    private func title(_ type: CyclistProfile.RiderType) -> LocalizedStringKey {
        switch type {
        case .climber: "Climber"
        case .puncheur: "Puncheur"
        case .sprinter: "Sprinter"
        case .timeTrialist: "Time trialist"
        case .endurance: "Endurance rider"
        case .allRounder: "All-rounder"
        case .developing: "Discovering your rider type"
        }
    }

    private func confidence(_ confidence: CyclistProfile.Confidence) -> LocalizedStringKey {
        switch confidence {
        case .limited: "Early impression · limited evidence"
        case .moderate: "Emerging pattern · moderate confidence"
        case .high: "Consistent pattern · high confidence"
        }
    }

    private func symbol(_ type: CyclistProfile.RiderType) -> String {
        switch type {
        case .climber: "mountain.2.fill"
        case .puncheur: "bolt.heart.fill"
        case .sprinter: "bolt.fill"
        case .timeTrialist: "speedometer"
        case .endurance: "road.lanes"
        case .allRounder: "bicycle"
        case .developing: "chart.xyaxis.line"
        }
    }
}

#Preview {
    NavigationStack {
        List { CyclistProfileSection() }
    }
    .environment(PreviewData.model())
}
