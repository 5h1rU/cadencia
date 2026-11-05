import AVFoundation
import SwiftUI
import CadenciaCore

struct CreatePlanView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var speech = SpeechRecognizer()
    @State private var answer = ""
    @State private var editingAnswer = false
    @State private var showProfile = false
    @State private var showHistory = false
    @State private var confirmRestart = false
    @State private var requestTask: Task<Void, Never>?
    @State private var speechTask: Task<Void, Never>?
    @FocusState private var focused: Bool

    // Only the debug fixture provides a transcript. The regular screen always uses the microphone.
    @State var previewTranscript: String?

    private var session: PlanConsultation.Session? { model.state.planConsultation }
    private var reply: PlanConsultation.Reply? { session?.reply }
    private var hasRides: Bool {
        model.state.activities.contains { $0.isCycling && $0.day >= model.today.adding(days: -42) && $0.day <= model.today }
    }
    private var recording: Bool { speech.isListening || previewTranscript != nil }
    private var canAnswer: Bool { model.aiCoachAvailable && !model.consultationBusy && model.consultationError == nil }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    review
                    if let update = reply?.profileUpdate, !update.isEmpty {
                        Button {
                            showProfile = true
                        } label: {
                            Label("Confirm profile details", systemImage: "person.crop.circle.badge.checkmark")
                        }
                        .buttonStyle(.bordered)
                    }
                    consultation
                    if session?.messages.contains(where: { $0.role == .athlete }) != true {
                        NavigationLink {
                            EventPlanFlow { dismiss() }
                        } label: {
                            Label("Prepare for an event", systemImage: "calendar")
                        }
                    }
                    if let messages = session?.messages, messages.count > 1 {
                        DisclosureGroup("Conversation history", isExpanded: $showHistory) {
                            VStack(alignment: .leading, spacing: 16) {
                                ForEach(messages) { message in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(message.role == .athlete ? "You" : "Coach")
                                            .fontWeight(.semibold)
                                        Text(verbatim: message.text)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .padding(.top, 16)
                        }
                    }
                }
                .font(.body)
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
                .frame(maxWidth: 600)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Your consultation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                if session?.messages.contains(where: { $0.role == .athlete }) == true {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button("Start over", systemImage: "arrow.counterclockwise", role: .destructive) { confirmRestart = true }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .accessibilityLabel("Consultation options")
                    }
                }
            }
            .confirmationDialog("Start this consultation over?", isPresented: $confirmRestart, titleVisibility: .visible) {
                Button("Start over", role: .destructive) {
                    speech.cancel()
                    requestTask?.cancel()
                    answer = ""
                    editingAnswer = false
                    requestTask = Task { await model.restartPlanConsultation() }
                }
            } message: {
                Text("Your answers and draft will be cleared.")
            }
            .sheet(isPresented: $showProfile) {
                NavigationStack {
                    CyclistMeasurementsView(proposed: reply?.profileUpdate)
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { showProfile = false } } }
                }
            }
            .task { await model.beginPlanConsultation() }
            .onChange(of: speech.status) { old, new in
                if old == .listening || old == .finishing, new != .listening && new != .finishing {
                    if !speech.transcript.isEmpty { answer = speech.transcript }
                    editingAnswer = true
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { speech.stop() }
            }
            .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { note in
                if note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt == AVAudioSession.InterruptionType.began.rawValue {
                    speech.stop()
                }
            }
            .onDisappear {
                speechTask?.cancel()
                speech.cancel()
                requestTask?.cancel()
                model.cancelPlanConsultationRequest()
            }
        }
    }

    private var review: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(hasRides ? "What I’ve reviewed" : "Your starting point", systemImage: hasRides ? "checkmark" : "bicycle")
                .labelStyle(ConsultationSectionLabel())
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 0) {
                if let review = reply?.review {
                    Text(verbatim: review)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 14)
                } else {
                    Text(hasRides ? "Your recent rides give us a starting point." : "Let’s get to know your riding.")
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 14)
                }
                Divider()
                LabeledContent("Weight") {
                    Text(model.state.weightKg.map { CyclistMeasureText.weight($0, metric: model.state.settings.unitsMetric) } ?? String(localized: "Not added"))
                }
                .padding(.vertical, 10)
                Divider()
                LabeledContent("FTP") {
                    Text(model.workingFTP.map(Format.watts) ?? String(localized: "Not set"))
                }
                .padding(.vertical, 10)
                if let relative = CyclistMeasurements.wattsPerKg(ftp: model.workingFTP, weightKg: model.state.weightKg) {
                    Divider()
                    LabeledContent("Relative power", value: CyclistMeasureText.relativePower(relative))
                        .padding(.vertical, 10)
                }
                Divider()
                ViewThatFits(in: .horizontal) {
                    HStack {
                        sourceLabel
                        Spacer(minLength: 12)
                        profileButton
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        sourceLabel
                        profileButton
                    }
                }
                .padding(.top, 10)
                if model.syncError != nil {
                    Text("Couldn’t refresh all training data.")
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                }
            }
            .padding(16)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
        }
    }

    private var sourceLabel: some View {
        Group {
            if hasRides { Text("Intervals.icu") }
            else if model.isSyncing { Text("Reading ride history…") }
            else { Text("No recent rides to review") }
        }
        .foregroundStyle(.secondary)
    }

    private var profileButton: some View {
        Button { showProfile = true } label: {
            Label("Profile details", systemImage: "chevron.right")
                .labelStyle(ConsultationTrailingSymbol())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
        .accessibilityIdentifier("consultation-profile")
    }

    private var consultation: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let reply {
                Text(verbatim: reply.question)
                    .font(.title2.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("consultation-question")
            } else {
                Text("What would you like us to work toward?")
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
            }
            if let issue = model.coachIssue {
                CoachIssueBanner(issue: issue) { model.dismissCoachIssue() }
            }
            if model.consultationBusy {
                if let message = session?.messages.last, message.role == .athlete {
                    Text(verbatim: message.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
                }
                ProgressView("Your coach is thinking…")
            } else if !model.aiCoachAvailable {
                Text("Connect your coach to begin the consultation.")
                    .foregroundStyle(.secondary)
                NavigationLink("Coach settings") { CoachSettingsView() }
                    .buttonStyle(.bordered)
            } else if let error = model.consultationError {
                Text(verbatim: error)
                    .foregroundStyle(.secondary)
                Button("Try again") { requestTask = Task { await model.requestPlanConsultation() } }
                    .buttonStyle(.bordered)
            } else {
                if let draft = reply?.draft, let session {
                    NavigationLink {
                        PlanConsultationReviewView(draft: draft, sessionID: session.id) { dismiss() }
                    } label: {
                        Text("Review plan").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("consultation-review-plan")
                }
                if reply?.topic == .otherTraining {
                    Text("Gym, CrossFit, running, swimming, or anything you’d like to add.")
                        .foregroundStyle(.secondary)
                } else if reply?.topic == .goal || reply == nil {
                    Text("Tell me what matters to you. We’ll shape the plan together.")
                        .foregroundStyle(.secondary)
                }
                if let suggestions = reply?.suggestedAnswers, !suggestions.isEmpty, !recording, !editingAnswer {
                    ViewThatFits(in: .horizontal) {
                        HStack { quickAnswers(suggestions) }
                        VStack(alignment: .leading) { quickAnswers(suggestions) }
                    }
                }
                answerControls
            }
        }
    }

    private func quickAnswers(_ suggestions: [String]) -> some View {
        ForEach(Array(suggestions.enumerated()), id: \.offset) { _, suggestion in
            Button { send(suggestion) } label: { Text(verbatim: suggestion) }
                .buttonStyle(.bordered)
                .disabled(!canAnswer)
        }
    }

    @ViewBuilder private var answerControls: some View {
        if recording || speech.status == .finishing {
            voiceCard
            Button {
                finishVoice()
                editingAnswer = true
                focused = true
            } label: {
                Label("Type instead", systemImage: "keyboard")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .disabled(speech.status == .finishing)
            Text("Review your words before sending.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        } else if speech.status == .preparing {
            ProgressView("Preparing voice input…")
            Button("Type instead") {
                speechTask?.cancel()
                speech.cancel()
                editingAnswer = true
                focused = true
            }
        } else {
            if speech.status == .denied {
                Text("Microphone or speech access is off. You can still type your answer.")
                    .foregroundStyle(.secondary)
            } else if speech.status == .unavailable || speechFailed {
                Text("Voice input isn’t available right now. You can still type your answer.")
                    .foregroundStyle(.secondary)
            }
            if editingAnswer {
                VStack(alignment: .leading, spacing: 12) {
                    TextField(reply?.draft == nil ? "Your answer" : "What would you change?", text: $answer, axis: .vertical)
                        .lineLimit(2...8)
                        .focused($focused)
                        .accessibilityIdentifier("consultation-answer")
                    HStack {
                        Button("Record answer", systemImage: "mic", action: startVoice)
                            .labelStyle(.iconOnly)
                            .frame(minWidth: 44, minHeight: 44)
                        Spacer()
                        Button("Send", action: { send(answer) })
                            .buttonStyle(.borderedProminent)
                            .disabled(!canAnswer || answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || answer.count > 6000)
                            .accessibilityIdentifier("consultation-send")
                    }
                }
                .padding(16)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
            } else {
                Button(action: startVoice) {
                    Label("Answer by voice", systemImage: "mic.fill").frame(maxWidth: .infinity, minHeight: 32)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canAnswer)
                Button {
                    editingAnswer = true
                    focused = true
                } label: {
                    Label("Type instead", systemImage: "keyboard").frame(maxWidth: .infinity, minHeight: 44)
                }
                .disabled(!canAnswer)
            }
        }
    }

    private var speechFailed: Bool {
        if case .failed = speech.status { return true }
        return false
    }

    private var voiceCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(speech.status == .finishing ? "Finishing transcript…" : "You’re speaking", systemImage: "mic")
                .foregroundStyle(Color.accentColor)
            Image(systemName: "waveform")
                .font(.system(size: 42))
                .foregroundStyle(Color.accentColor)
                .symbolEffect(.variableColor.iterative, isActive: recording && !reduceMotion)
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)
            if let transcript = previewTranscript ?? (speech.transcript.isEmpty ? nil : speech.transcript) {
                Text(verbatim: transcript)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("consultation-transcript")
            } else {
                Text("Listening…")
                    .foregroundStyle(.secondary)
            }
            Button(action: finishVoice) {
                VStack(spacing: 6) {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 50))
                        .accessibilityHidden(true)
                    Text("Finish answer").fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .disabled(speech.status == .finishing)
            .accessibilityIdentifier("consultation-finish-voice")
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
    }

    private func startVoice() {
        guard canAnswer else { return }
        focused = false
        speechTask = Task { await speech.start() }
    }

    private func finishVoice() {
        if let transcript = previewTranscript {
            answer = transcript
            previewTranscript = nil
            editingAnswer = true
        } else { speech.stop() }
    }

    private func send(_ value: String) {
        guard canAnswer else { return }
        focused = false
        answer = ""
        editingAnswer = false
        requestTask = Task { await model.sendPlanConsultationAnswer(value) }
    }
}

private struct ConsultationSectionLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon.foregroundStyle(Color.accentColor).accessibilityHidden(true)
            configuration.title
        }
    }
}

private struct ConsultationTrailingSymbol: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) { configuration.title; configuration.icon }
    }
}
