import Foundation

/// The coach's memory and the plan on Cadencia's backend, in the app's terms. The AI runs on this phone;
/// every interpretation is recorded here with its model and evidence, and Planning accepts or refuses it.
///
/// A command returns once it is recorded. What a policy does with it (the plan's verdict on a decision, a
/// plan created from an accepted draft, a week revised from an accepted intent) happens after, so the
/// methods that need that answer read the view again until it is there, up to `answerTimeout`.
public struct CoachBackend: Sendable {
    public var api: CadenciaAPI
    public var athleteId: String
    public var pollInterval: Duration
    public var answerTimeout: Duration
    private let pause: @Sendable (Duration) async throws -> Void

    public init(api: CadenciaAPI, athleteId: String, pollInterval: Duration = .milliseconds(700),
                answerTimeout: Duration = .seconds(20),
                pause: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.api = api
        self.athleteId = athleteId
        self.pollInterval = pollInterval
        self.answerTimeout = answerTimeout
        self.pause = pause
    }

    /// Where the AI ran, as the backend records it.
    static let device = CadenciaAPI.InterpretedOn.ios

    // MARK: Reads

    public func plan(after receipt: CadenciaAPI.Receipt? = nil) async throws -> CadenciaAPI.CurrentPlanState? {
        try await api.getCurrentPlan(athleteId, after: receipt)
    }

    /// The current plan once it is `planId`: a plan another model created reaches this view a moment later.
    public func plan(showing planId: String) async throws -> CadenciaAPI.CurrentPlanState? {
        var waited = Duration.zero
        while true {
            let plan = try await api.getCurrentPlan(athleteId)
            if plan?.planId == planId || waited >= answerTimeout { return plan }
            try await pause(pollInterval)
            waited += pollInterval
        }
    }

    public func decision(on day: Day, after receipt: CadenciaAPI.Receipt? = nil) async throws -> CadenciaAPI.TodayDecisionState? {
        try await api.getTodayDecision(BackendID.decision(athlete: athleteId, day: day), after: receipt)
    }

    public func thread(on day: Day, after receipt: CadenciaAPI.Receipt? = nil) async throws -> CadenciaAPI.ConversationThreadState? {
        try await api.getConversationThread(BackendID.conversation(athlete: athleteId, day: day), after: receipt)
    }

    public func consultation(_ id: String, after receipt: CadenciaAPI.Receipt? = nil) async throws -> CadenciaAPI.ConsultationViewState? {
        try await api.getConsultationView(id, after: receipt)
    }

    public func profile(after receipt: CadenciaAPI.Receipt? = nil) async throws -> CadenciaAPI.RiderProfileCardState? {
        try await api.getRiderProfileCard(athleteId, after: receipt)
    }

    // MARK: Daily decision

    /// Records the AI's decision for `day` and returns the plan's verdict on it: `accepted`, `refused` with
    /// the reason, or still `pending` if Planning did not answer within `answerTimeout`.
    public func recordDecision(on day: Day, planId: String, workout: Workout, note: CoachNote,
                               evidence: CadenciaAPI.EvidenceSnapshot, model: String) async throws -> CadenciaAPI.TodayDecisionState {
        let id = BackendID.decision(athlete: athleteId, day: day)
        let input = CadenciaAPI.RecordDailyDecisionInput(planId: planId, workout: .init(workout), note: .init(note),
                                                         evidence: evidence, model: model, interpretedOn: Self.device)
        let receipt = try await send { try await api.recordDailyDecision(id, input, commandId: $0) }
        return try await answer(read: { try await api.getTodayDecision(id, after: $0) }, after: receipt) { $0.status != .pending }
    }

    // MARK: Conversation

    /// Records what the athlete wrote, before the AI reads it.
    @discardableResult
    public func sendMessage(_ text: String, messageId: String, on day: Day) async throws -> CadenciaAPI.Receipt {
        try await send { try await api.sendMessage(BackendID.conversation(athlete: athleteId, day: day),
                                                   .init(messageId: messageId, text: text), commandId: $0) }
    }

    /// Records the coach's reply and the plan change it proposes, and returns the thread with both.
    public func recordReply(_ text: String, messageId: String, inReplyTo: String, intent: CadenciaAPI.Intent?, model: String,
                            on day: Day) async throws -> CadenciaAPI.ConversationThreadState? {
        let id = BackendID.conversation(athlete: athleteId, day: day)
        let input = CadenciaAPI.RecordCoachReplyInput(messageId: messageId, inReplyTo: inReplyTo, text: text, intent: intent,
                                                      model: model, interpretedOn: Self.device)
        let receipt = try await send { try await api.recordCoachReply(id, input, commandId: $0) }
        return try await api.getConversationThread(id, after: receipt)
    }

    /// Accepts the change a reply proposes and returns the thread once the plan has applied or refused it.
    public func acceptIntent(messageId: String, in conversation: String) async throws -> CadenciaAPI.ConversationThreadState? {
        let receipt = try await send { try await api.acceptIntent(conversation, .init(messageId: messageId), commandId: $0) }
        let thread = try await answer(read: { try await api.getConversationThread(conversation, after: $0) }, after: receipt) { thread in
            let status = thread.messages.first { $0.messageId == messageId }?.intentStatus
            return status != .accepted
        }
        return thread
    }

    public func dismissIntent(messageId: String, in conversation: String) async throws -> CadenciaAPI.ConversationThreadState? {
        let receipt = try await send { try await api.dismissIntent(conversation, .init(messageId: messageId), commandId: $0) }
        return try await api.getConversationThread(conversation, after: receipt)
    }

    // MARK: Consultation

    /// Opens a new consultation and returns its id.
    public func startConsultation(now: Date = Date()) async throws -> String {
        let id = BackendID.new(athlete: athleteId, prefix: "c", now: now)
        _ = try await send { try await api.startConsultation(id, commandId: $0) }
        return id
    }

    public func recordQuestion(_ text: String, model: String, in consultation: String) async throws -> CadenciaAPI.ConsultationViewState? {
        let receipt = try await send { try await api.recordCoachQuestion(consultation, .init(text: text, model: model, interpretedOn: Self.device), commandId: $0) }
        return try await api.getConsultationView(consultation, after: receipt)
    }

    public func answer(_ text: String, in consultation: String) async throws -> CadenciaAPI.ConsultationViewState? {
        let receipt = try await send { try await api.answerQuestion(consultation, .init(text: text), commandId: $0) }
        return try await api.getConsultationView(consultation, after: receipt)
    }

    public func recordDraft(_ draft: CadenciaAPI.PlanDraft, model: String, in consultation: String) async throws -> CadenciaAPI.ConsultationViewState? {
        let receipt = try await send { try await api.recordDraft(consultation, .init(draft: draft, model: model, interpretedOn: Self.device), commandId: $0) }
        return try await api.getConsultationView(consultation, after: receipt)
    }

    /// Accepts the consultation's draft as plan `planId` and returns the consultation once Planning answered:
    /// `created`, or `open` again with the reason it refused the plan. Still `accepted` if it did not answer
    /// within `answerTimeout`.
    public func acceptDraft(planId: String, in consultation: String) async throws -> CadenciaAPI.ConsultationViewState? {
        let receipt = try await send { try await api.acceptDraft(consultation, .init(planId: planId), commandId: $0) }
        return try await answer(read: { try await api.getConsultationView(consultation, after: $0) }, after: receipt) {
            $0.stage != .accepted
        }
    }

    // MARK: Rider profile

    /// Records that the AI is about to build the profile. False when an automatic attempt was already
    /// spent (or a profile exists): the caller does not call the AI then.
    public func recordProfileAttempt(automatic: Bool) async throws -> Bool {
        do {
            _ = try await send { try await api.recordProfileAttempt(athleteId, .init(automatic: automatic), commandId: $0) }
            return true
        } catch CadenciaAPIError.rejected(tag: "AutomaticAttemptUsed", _, _) {
            return false
        }
    }

    public func recordProfile(_ report: CyclistProfile.Report) async throws -> CadenciaAPI.RiderProfileCardState? {
        let input = CadenciaAPI.RecordProfileInput(report: .init(report), model: report.model, interpretedOn: Self.device)
        let receipt = try await send { try await api.recordProfile(athleteId, input, commandId: $0) }
        return try await api.getRiderProfileCard(athleteId, after: receipt)
    }

    // MARK: Plan changes that need no AI

    public func moveSession(_ sessionId: String, to day: Day, plan planId: String) async throws -> CadenciaAPI.CurrentPlanState? {
        let receipt = try await send { try await api.moveSession(planId, .init(sessionId: sessionId, toDay: day.iso), commandId: $0) }
        return try await api.getCurrentPlan(athleteId, after: receipt)
    }

    public func recordDayRequirement(_ instructions: String, maxMinutes: Int?, on day: Day, plan planId: String) async throws -> CadenciaAPI.CurrentPlanState? {
        let input = CadenciaAPI.DayRequirement(day: day.iso, instructions: instructions, maxMinutes: maxMinutes)
        let receipt = try await send { try await api.recordDayRequirement(planId, input, commandId: $0) }
        return try await api.getCurrentPlan(athleteId, after: receipt)
    }

    public func retirePlan(_ planId: String) async throws -> CadenciaAPI.CurrentPlanState? {
        let receipt = try await send { try await api.retirePlan(planId, commandId: $0) }
        return try await api.getCurrentPlan(athleteId, after: receipt)
    }

    // MARK: Helpers

    /// Sends one command. A transport failure is retried once with the same command id, so a command the
    /// server received before the connection dropped is not recorded twice.
    private func send(_ call: (String) async throws -> CadenciaAPI.Receipt) async throws -> CadenciaAPI.Receipt {
        let commandId = UUID().uuidString.lowercased()
        do {
            return try await call(commandId)
        } catch CadenciaAPIError.transport {
            try await pause(pollInterval)
            return try await call(commandId)
        }
    }

    /// Reads a view once it includes `receipt`, then again until `done` holds or `answerTimeout` passes.
    /// Returns the last state read; nil only when the view has no data at all.
    private func answer<State>(read: (CadenciaAPI.Receipt?) async throws -> State?, after receipt: CadenciaAPI.Receipt,
                               until done: (State) -> Bool) async throws -> State {
        guard var state = try await read(receipt) else { throw CadenciaAPIError.invalidResponse }
        var waited = Duration.zero
        while !done(state), waited < answerTimeout {
            try await pause(pollInterval)
            waited += pollInterval
            if let next = try await read(nil) { state = next }
        }
        return state
    }
}
