import AVFoundation
import SwiftUI
import CadenciaCore

/// Talk to the coach. A voice note or a line of text becomes a structured intent the athlete can
/// read back ("what I understood") and apply to the week with one tap. The conversation is the backend's:
/// this month's thread, with each proposal and what the plan did with it.
struct CoachView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    /// Created once here and handed to the composer, which owns the draft: a child's `@State` default
    /// value would be rebuilt every time this view re-renders.
    @State private var speech = SpeechRecognizer()
    @State private var didScrollInitially = false

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
                        ForEach(model.state.coachMessages, id: \.messageId) { message in
                            MessageRow(message: message, busy: model.coachBusy || model.coachThinking,
                                       accept: { Task { await model.acceptCoachProposal(messageID: message.messageId) } },
                                       dismiss: { Task { await model.dismissCoachProposal(messageID: message.messageId) } })
                            .id(message.messageId)
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
                        withAnimation { scrollToLatest(proxy) }
                    }
                    .onChange(of: model.coachBusy) { _, busy in
                        if busy { withAnimation { scrollToLatest(proxy) } }
                    }
                    // Opens at the latest message the first time the tab is shown; later visits keep the
                    // reader's position.
                    .task {
                        await model.refreshConversation()
                        guard !didScrollInitially else { return }
                        didScrollInitially = true
                        scrollToLatest(proxy)
                    }
                }
                CoachComposer(speech: speech)
            }
            .navigationTitle("Coach")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        switch model.coachSource {
                        case .chatGPTPlan:
                            Label("Using ChatGPT plan · \(model.state.settings.llmModel)", systemImage: "sparkles")
                            Link(destination: ChatGPTAuth.usageSettingsURL) { Label("Manage usage", systemImage: "arrow.up.right.square") }
                        case .apiKey:
                            Label("Using \(model.state.settings.llmModel)", systemImage: "sparkles")
                        case nil:
                            Label("No coach connected", systemImage: "exclamationmark.triangle")
                        }
                    } label: {
                        Label("Coach options", systemImage: "ellipsis.circle").labelStyle(.iconOnly)
                    }
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

    /// Brings the newest thing into view: the "Thinking…" row while a reply is pending, else the last message.
    private func scrollToLatest(_ proxy: ScrollViewProxy) {
        if model.coachBusy {
            proxy.scrollTo("busy", anchor: .bottom)
        } else if let last = model.state.coachMessages.last {
            proxy.scrollTo(last.messageId, anchor: .bottom)
        }
    }
}

/// The message field, the voice button and the coach's status lines. A view of its own, so typing and
/// live transcripts re-render only the composer, not the conversation. It never reads `model.state`.
private struct CoachComposer: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let speech: SpeechRecognizer
    @State private var draft = ""
    @FocusState private var composing: Bool

    var body: some View {
        VStack(spacing: 8) {
            if let issue = model.coachIssue {
                CoachIssueBanner(issue: issue) { model.dismissCoachIssue() }
                    .padding(.horizontal)
            }
            if let notice = model.coachNotice {
                Text(notice).font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
            }
            // A chat reply has its own "Thinking…" row; this explains why the apply buttons wait meanwhile.
            if model.coachThinking, !model.coachBusy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("The coach is reading your data…")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .accessibilityElement(children: .combine)
            }
            // One status line for the whole voice note, the same height in every phase, so the field never jumps.
            if speech.isCapturing {
                HStack(spacing: 8) {
                    if speech.isListening {
                        Image(systemName: "waveform")
                            .symbolEffect(.variableColor.iterative, isActive: !reduceMotion)
                            .foregroundStyle(.red)
                            .accessibilityHidden(true)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    if speech.status == .preparing {
                        Text("Preparing voice input…")
                    } else if !speech.transcript.isEmpty {
                        // Finishing keeps the words where they were heard; only the icon turns into a spinner.
                        Text(verbatim: speech.transcript).lineLimit(2)
                    } else if speech.isListening {
                        Text("Listening…")
                    } else {
                        Text("Finishing transcript…")
                    }
                    Spacer()
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .accessibilityElement(children: .combine)
            }
            if case .denied = speech.status {
                Text("Microphone or speech access is off. Enable it in Settings to use voice notes.").font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
            } else if speech.status == .unavailable {
                Text("Voice input isn’t available right now. You can still type your answer.").font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
            } else if case .failed = speech.status {
                Text("Voice input isn’t available right now. You can still type your answer.").font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
            }
            HStack(spacing: 12) {
                // Stops (or, while preparing, cancels) any capture; a new one can't start during a reply.
                Button {
                    if speech.isCapturing { speech.stop() } else { Task { await speech.start() } }
                } label: {
                    Label(micTitle, systemImage: speech.isCapturing ? "stop.circle.fill" : "mic.circle.fill")
                        .labelStyle(.iconOnly)
                        .font(.largeTitle)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.borderless)
                .tint(speech.isListening ? Color.red : Color.accentColor)
                .disabled(speech.status == .finishing || (model.coachBusy && !speech.isCapturing))
                // Only while it starts a capture, so stopping keeps normal VoiceOver feedback (the microphone is already off then).
                .accessibilityAddTraits(speech.isCapturing ? [] : .startsMediaSession)
                TextField("Message the coach", text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                    .focused($composing)
                    .disabled(speech.isCapturing)
                    .onSubmit(send)
                Button(action: send) {
                    Label("Send", systemImage: "arrow.up.circle.fill")
                        .labelStyle(.iconOnly)
                        .font(.largeTitle)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.borderless)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.coachBusy || speech.isCapturing)
            }
            .padding(.horizontal)
        }
        // Even insets, so a status line never sits on the bar's top edge.
        .padding(.vertical, 8)
        .background(.bar)
        .onChange(of: speech.status) { old, new in
            if old == .listening || old == .finishing, new != .listening && new != .finishing, !speech.transcript.isEmpty {
                draft = speech.transcript
            }
        }
    }

    private var micTitle: LocalizedStringKey { speech.isCapturing ? "Stop listening" : "Record a voice note" }

    private func send() {
        // `.onSubmit` ignores Send's disabled state. Never clear a draft the coach would drop (a reply in flight).
        guard !speech.isCapturing, !model.coachBusy,
              !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
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
    @State private var signInError: String?

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
                            guard !signingIn else { return }
                            signingIn = true
                            Task {
                                defer { signingIn = false }
                                do { try await model.signInWithChatGPT() }
                                catch ChatGPTSignIn.Failure.cancelled {}
                                catch { signInError = error.localizedDescription }
                            }
                        } label: {
                            // The title keeps the pill's width while the spinner shows.
                            Text("Continue with ChatGPT")
                                .opacity(signingIn ? 0 : 1)
                                .overlay { if signingIn { ProgressView() } }
                        }
                        .buttonStyle(.borderedProminent).controlSize(.small).disabled(signingIn)
                    case .notEligible:
                        EmptyView()
                    }
                    Button("Dismiss", action: dismiss).buttonStyle(.bordered).controlSize(.small)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .alert("Could not sign in", isPresented: Binding(get: { signInError != nil }, set: { if !$0 { signInError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(signInError ?? "") }
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

/// One line of the conversation. Coach replies carry the change they propose and what became of it.
struct MessageRow: View {
    let message: CadenciaAPI.ThreadMessage
    var busy = false
    let accept: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            if message.role == .athlete { Spacer(minLength: 48) }
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: message.text)
                if let intent = message.intent {
                    UnderstoodCard(intent: intent, status: message.intentStatus ?? .proposed, refusal: message.refusal,
                                   busy: busy, accept: accept, dismiss: dismiss)
                }
            }
            .padding(12)
            .background(message.role == .athlete ? Color.accentColor.opacity(0.15) : Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
            if message.role == .coach { Spacer(minLength: 48) }
        }
        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
    }
}

/// "What I understood": the days the coach would change, line by line, with a single confirm. The plan
/// applies it (or refuses it, with its reason) only once the athlete accepts.
struct UnderstoodCard: View {
    @Environment(AppModel.self) private var model
    let intent: CadenciaAPI.Intent
    let status: CadenciaAPI.ThreadMessage.IntentStatus
    let refusal: String?
    var busy = false
    let accept: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What I understood").font(.caption).foregroundStyle(.secondary).textCase(.uppercase)
            ForEach(intent.limits, id: \.day) { limit in
                if let day = Day(iso: limit.day) {
                    Label {
                        if limit.unavailable { Text("\(Format.day(day)): no training") }
                        else if let m = limit.maxMinutes { Text("\(Format.day(day)): up to \(m) min") }
                        else { Text("\(Format.day(day)): your request for the session") }
                    } icon: { Image(systemName: limit.maxMinutes == nil && !limit.unavailable ? "bicycle" : "clock") }
                }
            }
            switch status {
            case .proposed:
                HStack {
                    Button(action: accept) {
                        Label("Update my week", systemImage: "calendar.badge.checkmark").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Not now", action: dismiss).buttonStyle(.bordered)
                }
                .disabled(busy || !model.isBackendConnected)
                .padding(.top, 4)
            case .accepted:
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Your plan is updating…") }
                    .foregroundStyle(.secondary)
            case .applied:
                Label("Week updated", systemImage: "checkmark").foregroundStyle(.secondary)
            case .dismissed:
                Label("Not applied", systemImage: "xmark").foregroundStyle(.secondary)
            case .refused:
                Label("Your plan couldn't take this change.", systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                if let refusal { Text(verbatim: refusal).font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .font(.subheadline)
    }
}

#Preview {
    CoachView().environment(PreviewData.model())
}
