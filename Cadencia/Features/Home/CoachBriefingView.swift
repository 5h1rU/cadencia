import SwiftUI
import CadenciaCore

/// The coach's complete daily note and actions, reached from the compact Home link.
struct CoachBriefingView: View {
    @Environment(AppModel.self) private var model
    /// Coach settings are pushed from the list, not from the setup row: the row goes away as soon as the
    /// coach is connected, and a link leaving the screen would pop Settings (and the ChatGPT welcome sheet).
    @State private var showsCoachSettings = false

    private var ai: DailyPrescription? { model.state.today?.day == model.today ? model.state.today?.ai : nil }

    /// A daily decision or a chat reply is running. A tap now would only be queued until it ends, so the
    /// ask buttons wait, as Coach's apply buttons do.
    private var coachRequestInFlight: Bool { model.coachThinking || model.coachBusy }

    var body: some View {
        List {
            briefingSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Your coach")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showsCoachSettings) { CoachSettingsView() }
        .refreshable { await model.refresh() }
        .task(id: model.completedRideToday?.id) {
            if let id = model.completedRideToday?.id { await model.syncDebriefNote(for: id) }
        }
    }

    @ViewBuilder private var briefingSection: some View {
        if model.isTodayWorkoutCompleted {
            Section {
                Label("Today's session is complete.", systemImage: "checkmark.circle.fill")
                    .font(.headline).foregroundStyle(.green)
            }
            if let id = model.completedRideToday?.id, let ride = model.ride(id: id) {
                DebriefSections(ride: ride)
            } else {
                Section {
                    Text("Your session is saved. The coach's debrief appears in session details.")
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            InfoSection(hasInformation: ai != nil) {
                if !model.aiCoachAvailable {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Connect your coach", systemImage: "sparkles").font(.headline)
                        Text("Cadencia's coach is an AI that reads your recovery, load, power and plan every day and decides your session. Sign in with ChatGPT to use your plan, or add an OpenAI API key.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    Button { showsCoachSettings = true } label: {
                        Label("Set up the coach", systemImage: "arrow.right.circle")
                    }
                } else if let ai, let readiness = model.readiness {
                    VStack(alignment: .leading, spacing: 20) {
                        VStack(alignment: .leading, spacing: 8) {
                            if let headline = model.coachNote?.headline, !headline.isEmpty {
                                Text(headline).font(.title2.weight(.semibold))
                            }
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Circle().fill(readiness.level.tint)
                                    .frame(width: 8, height: 8)
                                    .accessibilityHidden(true)
                                Text(readinessSentence(readiness.level))
                                    .font(.subheadline).foregroundStyle(.secondary)
                                if model.coachThinking { ProgressView().controlSize(.mini) }
                            }
                        }
                        VStack(alignment: .leading, spacing: 16) {
                            if let note = model.coachNote {
                                if !note.body.isEmpty {
                                    notePart("Your body", text: note.body)
                                }
                                if !note.session.isEmpty {
                                    notePart("Today", text: note.session)
                                }
                                if let watch = note.watch {
                                    notePart("Keep in mind", text: watch)
                                }
                            }
                            ForEach(ai.flags, id: \.self) { flag in
                                Label(flagText(flag), systemImage: "flag").font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 8)
                    .accessibilityIdentifier("coach-briefing")
                    if let notice = model.coachNotice {
                        Label(notice, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.secondary)
                    }
                    askAgainButton
                } else if model.workingFTP == nil {
                    Label("Set an FTP in Intervals.icu to get prescriptions.", systemImage: "exclamationmark.circle")
                } else if model.coachThinking {
                    HStack(spacing: 12) {
                        ProgressView()
                        VStack(alignment: .leading, spacing: 2) {
                            Text("The coach is reading your data…")
                            Text("Recovery, load, power curve and plan. This takes a few seconds.").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                } else if let notice = model.coachNotice {
                    Label(notice, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                    Button("Ask the coach", systemImage: "sparkles") { Task { await model.askCoachForToday(force: true) } }
                        .disabled(coachRequestInFlight)
                } else if let issue = model.coachIssue {
                    Label(issueText(issue), systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                } else {
                    Button("Ask the coach", systemImage: "sparkles") { Task { await model.askCoachForToday(force: true) } }
                        .disabled(coachRequestInFlight)
                }
            } header: {
                Text(Format.day(model.today))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } information: {
                if let ai {
                    Text("Decided \(ai.generatedAt.formatted(date: .omitted, time: .shortened)) from your recovery, load, power and plan. Every number was range-checked before it reached the trainer.")
                }
            }
        }
    }

    private func readinessSentence(_ level: Readiness.Level) -> LocalizedStringKey {
        switch level {
        case .rest: return "Your body needs rest today."
        case .easy: return "Take it easy in today's session."
        case .normal: return "You're ready for today's session."
        case .strong: return "You're recovering well today."
        }
    }

    private func notePart(_ title: LocalizedStringKey, text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            Text(text).font(.body).lineSpacing(2)
        }
    }

    private var askAgainButton: some View {
        Button {
            Task { await model.askCoachForToday(force: true) }
        } label: {
            // The row keeps its label. Only a decision for today shows progress; a chat reply just holds the button.
            HStack {
                Label("Ask the coach again", systemImage: "arrow.triangle.2.circlepath")
                if model.coachThinking { Spacer(); ProgressView() }
            }
        }
        .disabled(coachRequestInFlight)
    }

    private func issueText(_ issue: AppModel.CoachIssue) -> LocalizedStringKey {
        switch issue {
        case .usageLimit: return "You've reached the usage limit of your ChatGPT plan for now. Manage it in Settings → Coach, or wait for it to reset."
        case .notEligible: return "Your ChatGPT account can't share its plan with apps. Use an API key in Settings → Coach."
        case .signInAgain: return "ChatGPT no longer accepts this sign-in. Sign in again in Settings → Coach."
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

}

#if DEBUG
#Preview {
    NavigationStack { CoachBriefingView() }.environment(PreviewData.homeModel())
}
#endif
