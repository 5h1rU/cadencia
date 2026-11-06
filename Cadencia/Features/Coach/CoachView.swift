import AVFoundation
import SwiftUI
import CadenciaCore

/// Talk to the coach. A voice note or a line of text becomes a structured intent the athlete can
/// read back ("what I understood") and apply to the week with one tap.
struct CoachView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    /// Created once here and handed to the composer, which owns the draft: a child's `@State` default
    /// value would be rebuilt every time this view re-renders.
    @State private var speech = SpeechRecognizer()
    @State private var didScrollInitially = false
    @State private var confirmClear = false

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
                        withAnimation { scrollToLatest(proxy) }
                    }
                    .onChange(of: model.coachBusy) { _, busy in
                        if busy { withAnimation { scrollToLatest(proxy) } }
                    }
                    // Opens at the latest message the first time the tab is shown; later visits keep the
                    // reader's position.
                    .task {
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
                        Button("Clear conversation", systemImage: "trash", role: .destructive) { confirmClear = true }
                            .disabled(model.state.coachMessages.isEmpty)
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
            .confirmationDialog("Clear this conversation?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear conversation", role: .destructive) { model.clearCoachHistory() }
            } message: {
                Text("Suggestions you haven't applied are removed. Changes you already applied stay.")
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
            proxy.scrollTo(last.id, anchor: .bottom)
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
        // Read once per render: for today's proposal it checks the coach brief's fingerprint.
        let unavailable = requestUnavailable
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
                        .contentShape(.rect)
                    }
                    // Only the link navigates; a default-styled link would take over the whole chat row.
                    .buttonStyle(.borderless)
                } else if request.day > model.today {
                    Text(request.instructions)
                    Text("The coach will build this workout from your recovery on that day.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if unavailable, !applied {
                    Text("Your training context changed. Ask the coach for an updated workout preview.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Button(action: apply) {
                Label(buttonTitle, systemImage: applied ? "checkmark" : "calendar.badge.checkmark")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(applied || busy || unavailable || !intent.needsClarification.isEmpty)
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
