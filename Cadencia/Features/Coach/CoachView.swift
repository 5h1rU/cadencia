import SwiftUI
import CadenciaCore

/// Talk to the coach. A voice note or a line of text becomes a structured intent the athlete can
/// read back ("what I understood") and apply to the week with one tap.
struct CoachView: View {
    @Environment(AppModel.self) private var model
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
                            MessageRow(message: message) { intent in
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
                        if model.state.settings.llmEnabled {
                            Label("Using \(model.state.settings.llmModel)", systemImage: "sparkles")
                        } else {
                            Label("On-device interpretation", systemImage: "iphone")
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .onChange(of: speech.transcript) { _, text in if speech.isListening || !text.isEmpty { draft = text } }
        }
    }

    private var composer: some View {
        VStack(spacing: 8) {
            if speech.isListening {
                HStack(spacing: 8) {
                    Image(systemName: "waveform").symbolEffect(.variableColor.iterative, isActive: true).foregroundStyle(.red)
                    Text(draft.isEmpty ? "Listening…" : draft).lineLimit(2).font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal)
            }
            if case .denied = speech.status {
                Text("Microphone or speech access is off. Enable it in Settings to use voice notes.").font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
            }
            HStack(spacing: 12) {
                Button {
                    if speech.isListening { speech.stop() } else { Task { await speech.start() } }
                } label: {
                    Image(systemName: speech.isListening ? "stop.circle.fill" : "mic.circle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(speech.isListening ? .red : Color.accentColor)
                }
                .accessibilityLabel(speech.isListening ? "Stop listening" : "Record a voice note")
                TextField("Message the coach", text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                    .focused($composing)
                    .onSubmit(send)
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 30))
                }
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || model.coachBusy)
                .accessibilityLabel("Send")
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        .background(.bar)
    }

    private func send() {
        let text = draft
        draft = ""
        if speech.isListening { speech.stop() }
        Task { await model.sendToCoach(text) }
    }
}

/// One line of the conversation. Coach replies carry the structured reading and an apply button.
struct MessageRow: View {
    let message: AppState.CoachMessage
    let apply: (CoachIntent) -> Void

    var body: some View {
        HStack(alignment: .top) {
            if message.role == .athlete { Spacer(minLength: 48) }
            VStack(alignment: .leading, spacing: 8) {
                Text(message.text)
                if let intent = message.intent, !intent.isEmpty {
                    UnderstoodCard(intent: intent, applied: message.applied) { apply(intent) }
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
    let intent: CoachIntent
    let applied: Bool
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
            Button(action: apply) {
                Label(applied ? "Week updated" : "Update my week", systemImage: applied ? "checkmark" : "calendar.badge.checkmark")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(applied)
            .padding(.top, 4)
        }
        .font(.subheadline)
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
