import AVFoundation
import SwiftUI
import CadenciaCore

/// Talk to the coach. A voice note or a line of text becomes a structured intent the athlete can
/// read back ("what I understood") and apply to the week with one tap.
struct CoachView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var speech = SpeechRecognizer()
    @State private var draft = ""
    @FocusState private var composing: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    List {
                        if model.state.coachMessages.isEmpty {
                            Section {
                                ContentUnavailableView {
                                    Label("Tell the coach what changed", systemImage: "waveform.and.mic")
                                } description: {
                                    Text("“Saturday I have a 120 km group ride.” “Only 45 minutes on Thursday.” “Legs are heavy.” The week adapts; the long-range plan stays.")
                                }
                            }
                            .listRowBackground(Color.clear)
                        }
                        ForEach(model.state.coachMessages) { message in
                            MessageRow(message: message, busy: model.coachBusy || model.coachThinking) { intent in
                                Task { await model.applyIntent(intent, messageID: message.id) }
                            }
                            .id(message.id)
                            .listRowSeparator(.hidden)
                        }
                        if model.coachBusy {
                            HStack { ProgressView(); Text("Thinking…").foregroundStyle(.secondary) }
                                .listRowSeparator(.hidden)
                                .id("busy")
                        }
                    }
                    .listStyle(.plain)
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: model.state.coachMessages.count) { _, _ in
                        if let last = model.state.coachMessages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                    }
                }
                composer
            }
            .navigationTitle("Coach")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Clear conversation", systemImage: "trash", role: .destructive) { model.clearCoachHistory() }
                        switch model.coachSource {
                        case .chatGPTPlan:
                            Label("Using ChatGPT plan · \(model.state.settings.llmModel)", systemImage: "sparkles")
                            Link(destination: ChatGPTAuth.usageSettingsURL) { Label("Manage usage", systemImage: "arrow.up.right.square") }
                        case .apiKey:
                            Label("Using \(model.state.settings.llmModel)", systemImage: "sparkles")
                        case nil:
                            Label("No coach connected", systemImage: "exclamationmark.triangle")
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .onChange(of: speech.status) { old, new in
                if old == .listening || old == .finishing, new != .listening && new != .finishing, !speech.transcript.isEmpty {
                    draft = speech.transcript
                }
            }
            .onChange(of: scenePhase) { _, phase in if phase == .background { speech.stop() } }
            .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { note in
                if note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt == AVAudioSession.InterruptionType.began.rawValue {
                    speech.stop()
                }
            }
            .onDisappear { speech.cancel() }
        }
    }

    private var composer: some View {
        VStack(spacing: 8) {
            if let issue = model.coachIssue {
                CoachIssueBanner(issue: issue) { model.dismissCoachIssue() }
                    .padding(.horizontal)
                    .padding(.top, 8)
            }
            if let notice = model.coachNotice {
                Text(notice).font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
            }
            if speech.status == .preparing {
                ProgressView("Preparing voice input…").padding(.horizontal)
            } else if speech.status == .finishing {
                ProgressView("Finishing transcript…").padding(.horizontal)
            } else if speech.isListening {
                HStack(spacing: 8) {
                    Image(systemName: "waveform").symbolEffect(.variableColor.iterative, isActive: true).foregroundStyle(.red)
                    Text(speech.transcript.isEmpty ? String(localized: "Listening…") : speech.transcript)
                        .lineLimit(2).font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal)
            }
            if case .denied = speech.status {
                Text("Microphone or speech access is off. Enable it in Settings to use voice notes.").font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
            } else if speech.status == .unavailable {
                Text("Voice input isn’t available right now. You can still type your answer.").font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
            } else if case .failed = speech.status {
                Text("Voice input isn’t available right now. You can still type your answer.").font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
            }
            HStack(spacing: 12) {
                Button {
                    if speech.isListening { speech.stop() } else { Task { await speech.start() } }
                } label: {
                    Image(systemName: speech.isListening ? "stop.circle.fill" : "mic.circle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(speech.isListening ? .red : Color.accentColor)
                }
                .disabled(speech.status == .preparing || speech.status == .finishing || model.coachBusy)
                .accessibilityLabel(speech.isListening ? "Stop listening" : "Record a voice note")
                TextField("Message the coach", text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                    .focused($composing)
                    .disabled(speech.isCapturing)
                    .onSubmit(send)
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 30))
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.coachBusy || speech.isCapturing)
                .accessibilityLabel("Send")
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        .background(.bar)
    }

    private func send() {
        guard !speech.isCapturing else { return }
        let text = draft
        draft = ""
        Task { await model.sendToCoach(text) }
    }
}

/// ChatGPT-plan states the athlete must act on. "Manage usage" is the primary action on a usage limit,
/// as OpenAI's guidelines ask; a dead sign-in points to Settings → Coach.
struct CoachIssueBanner: View {
    @Environment(AppModel.self) private var model
    let issue: AppModel.CoachIssue
    let dismiss: () -> Void
    @State private var signingIn = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).foregroundStyle(.orange).padding(.top, 2)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.footnote).foregroundStyle(.secondary)
                HStack {
                    switch issue {
                    case .usageLimit:
                        Link("Manage usage", destination: ChatGPTAuth.usageSettingsURL).buttonStyle(.borderedProminent).controlSize(.small)
                    case .signInAgain:
                        Button {
                            signingIn = true
                            Task { defer { signingIn = false }; try? await model.signInWithChatGPT() }
                        } label: {
                            if signingIn { ProgressView() } else { Text("Continue with ChatGPT") }
                        }
                        .buttonStyle(.borderedProminent).controlSize(.small).disabled(signingIn)
                    case .notEligible:
                        EmptyView()
                    }
                    Button("Dismiss", action: dismiss).controlSize(.small)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private var symbol: String {
        switch issue {
        case .usageLimit: return "gauge.with.needle"
        case .signInAgain: return "person.crop.circle.badge.exclamationmark"
        case .notEligible: return "exclamationmark.triangle"
        }
    }

    private var title: LocalizedStringKey {
        switch issue {
        case .usageLimit: return "Usage limit reached"
        case .signInAgain: return "Sign in to ChatGPT again"
        case .notEligible: return "ChatGPT plan not available"
        }
    }

    private var detail: LocalizedStringKey {
        switch issue {
        case .usageLimit: return "Your ChatGPT plan or this app's limit is used up for now. Review it in ChatGPT settings; meanwhile the coach answers without ChatGPT."
        case .signInAgain: return "The saved sign-in no longer works. Until you sign in again the coach answers without ChatGPT."
        case .notEligible: return "This ChatGPT account can't share its plan with apps. Add an API key in Settings → Coach to keep using the language model."
        }
    }
}

/// One line of the conversation. Coach replies carry the structured reading and an apply button.
struct MessageRow: View {
    let message: AppState.CoachMessage
    var busy = false
    let apply: (CoachIntent) -> Void

    var body: some View {
        HStack(alignment: .top) {
            if message.role == .athlete { Spacer(minLength: 48) }
            VStack(alignment: .leading, spacing: 8) {
                Text(message.text)
                if let intent = message.intent, !intent.isEmpty {
                    UnderstoodCard(intent: intent, applied: message.applied, proposal: message.workoutProposal, busy: busy) { apply(intent) }
                }
                if let intent = message.intent, !intent.needsClarification.isEmpty {
                    ForEach(intent.needsClarification, id: \.self) { q in
                        Label(q, systemImage: "questionmark.circle").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(12)
            .background(message.role == .athlete ? Color.accentColor.opacity(0.15) : Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
            if message.role == .coach { Spacer(minLength: 48) }
        }
        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
    }
}

/// "What I understood": the structured intent, line by line, with a single confirm.
struct UnderstoodCard: View {
    @Environment(AppModel.self) private var model
    let intent: CoachIntent
    let applied: Bool
    var proposal: AppState.WorkoutProposal?
    var busy = false
    let apply: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What I understood").font(.caption).foregroundStyle(.secondary).textCase(.uppercase)
            if let e = intent.event {
                Label {
                    Text("\(e.name), \(Format.day(e.day))\(e.distanceKm.map { String(format: ", %.0f km", $0) } ?? "") · priority \(e.priority.rawValue.uppercased())")
                } icon: { Image(systemName: e.isRace ? "flag.checkered" : "person.3") }
            }
            ForEach(intent.constraints) { c in
                Label {
                    if c.unavailable { Text("\(Format.day(c.day)): no training") }
                    else if let m = c.maxMinutes { Text("\(Format.day(c.day)): up to \(m) min") }
                } icon: { Image(systemName: "clock") }
            }
            if let legs = intent.feeling {
                Label(legsText(legs), systemImage: "figure.walk")
            }
            if let goal = intent.goal {
                Label { Text("Goal: \(Text(goal.title))") } icon: { Image(systemName: goal.symbol) }
            }
            if let request = intent.workoutRequest {
                Label(Format.day(request.day), systemImage: "bicycle")
                if let proposal {
                    NavigationLink {
                        WorkoutDetailView(workout: proposal.prescription.workout, ftp: proposal.ftp)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Review proposed workout").fontWeight(.semibold)
                            Text(proposal.prescription.workout.name)
                            Text("\(Format.minutes(proposal.prescription.workout.totalDuration)) · \(proposal.prescription.workout.estimatedLoad) TSS")
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if request.day > model.today {
                    Text(request.instructions)
                    Text("The coach will build this workout from your recovery on that day.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if requestUnavailable, !applied {
                    Text("Your training context changed. Ask the coach for an updated workout preview.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Button(action: apply) {
                Label(buttonTitle, systemImage: applied ? "checkmark" : "calendar.badge.checkmark")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(applied || busy || requestUnavailable || !intent.needsClarification.isEmpty)
            .padding(.top, 4)
        }
        .font(.subheadline)
    }

    private var buttonTitle: LocalizedStringKey {
        if intent.workoutRequest != nil {
            if proposal != nil { return applied ? "Workout updated" : "Use this workout" }
            return applied ? "Workout request saved" : "Save workout request"
        }
        return applied ? "Week updated" : "Update my week"
    }

    private var requestUnavailable: Bool {
        guard let request = intent.workoutRequest else { return false }
        if request.day < model.today || model.state.isWorkoutCompleted(on: request.day) { return true }
        if request.day == model.today {
            guard let proposal else { return true }
            return !model.isWorkoutProposalCurrent(proposal)
        }
        return false
    }

    private func legsText(_ legs: SubjectiveFeedback.Legs) -> LocalizedStringKey {
        switch legs {
        case .fresh: return "Legs feel fresh"
        case .ok: return "Legs feel normal"
        case .heavy: return "Legs feel heavy"
        }
    }
}

#Preview {
    CoachView().environment(PreviewData.model())
}
