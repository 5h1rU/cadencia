import Foundation

/// The coach's memory and the plan on Cadencia's backend, in the app's terms. The AI runs on this phone;
/// every interpretation is recorded here with its model and evidence, and Planning accepts or refuses it.
///
/// A command returns once it is recorded. What a policy does with it (the plan's verdict on a decision, a
/// plan created from an accepted draft, a week revised from an accepted intent) happens after, so the
/// methods that need that answer read the view again until it is there, up to `answerTimeout`.
public struct CoachBackend: Sendable {
    public var api: CadenciaAPI
    public var athleteId: CadenciaAPI.AthleteId
    public var pollInterval: Duration
    public var answerTimeout: Duration
    private let pause: @Sendable (Duration) async throws -> Void

    public init(api: CadenciaAPI, athleteId: CadenciaAPI.AthleteId, pollInterval: Duration = .milliseconds(700),
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
    public func plan(showing planId: CadenciaAPI.PlanId) async throws -> CadenciaAPI.CurrentPlanState? {
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

    public func consultation(_ id: CadenciaAPI.ConsultationId, after receipt: CadenciaAPI.Receipt? = nil) async throws -> CadenciaAPI.ConsultationViewState? {
        try await api.getConsultationView(id, after: receipt)
    }

    public func profile(after receipt: CadenciaAPI.Receipt? = nil) async throws -> CadenciaAPI.RiderProfileCardState? {
        try await api.getRiderProfileCard(athleteId, after: receipt)
    }

    // MARK: Daily decision

    /// Records the AI's decision for `day` and returns the plan's verdict on it: `accepted`, `refused` with
    /// the reason, or still `pending` if Planning did not answer within `answerTimeout`. Throws
    /// `CadenciaAPI.InvalidValue`, before sending anything, when the workout is outside the domain's ranges.
    public func recordDecision(on day: Day, planId: CadenciaAPI.PlanId, workout: Workout, note: CoachNote,
                               evidence: CadenciaAPI.EvidenceSnapshot, model: String) async throws -> CadenciaAPI.TodayDecisionState {
        let id = BackendID.decision(athlete: athleteId, day: day)
        let input = try CadenciaAPI.RecordDailyDecisionInput(planId: planId, workout: .init(workout), note: .init(note),
                                                             evidence: evidence, model: .init(model), interpretedOn: Self.device)
        let receipt = try await send { try await api.recordDailyDecision(id, input, commandId: $0) }
        return try await answer(read: { try await api.getTodayDecision(id, after: $0) }, after: receipt) { $0.status != .pending }
    }

    // MARK: Conversation

    /// Records what the athlete wrote, before the AI reads it.
    @discardableResult
    public func sendMessage(_ text: String, messageId: CadenciaAPI.MessageId, on day: Day) async throws -> CadenciaAPI.Receipt {
        let input = try CadenciaAPI.SendMessageInput(messageId: messageId, text: .init(text: text))
        return try await send { try await api.sendMessage(BackendID.conversation(athlete: athleteId, day: day), input, commandId: $0) }
    }

    /// Records the coach's reply and the plan change it proposes, and returns the thread with both.
    public func recordReply(_ text: String, messageId: CadenciaAPI.MessageId, inReplyTo: CadenciaAPI.MessageId, intent: CadenciaAPI.Intent?,
                            model: String, on day: Day) async throws -> CadenciaAPI.ConversationThreadState? {
        let id = BackendID.conversation(athlete: athleteId, day: day)
        let input = try CadenciaAPI.RecordCoachReplyInput(messageId: messageId, inReplyTo: inReplyTo, text: .init(fitting: text),
                                                          intent: intent, model: .init(model), interpretedOn: Self.device)
        let receipt = try await send { try await api.recordCoachReply(id, input, commandId: $0) }
        return try await api.getConversationThread(id, after: receipt)
    }

    /// Accepts the change a reply proposes and returns the thread once the plan has applied or refused it.
    /// `today` is the athlete's local day: the plan revises the week from it, and refuses a change whose days
    /// have all passed (`IntentExpired`).
    public func acceptIntent(messageId: CadenciaAPI.MessageId, in conversation: CadenciaAPI.ConversationId,
                             today: Day) async throws -> CadenciaAPI.ConversationThreadState? {
        let input = CadenciaAPI.AcceptIntentInput(messageId: messageId, today: .init(today))
        let receipt = try await send { try await api.acceptIntent(conversation, input, commandId: $0) }
        let thread = try await answer(read: { try await api.getConversationThread(conversation, after: $0) }, after: receipt) { thread in
            let status = thread.messages.first { $0.messageId == messageId }?.intentStatus
            return status != .accepted
        }
        return thread
    }

    public func dismissIntent(messageId: CadenciaAPI.MessageId, in conversation: CadenciaAPI.ConversationId) async throws -> CadenciaAPI.ConversationThreadState? {
        let receipt = try await send { try await api.dismissIntent(conversation, .init(messageId: messageId), commandId: $0) }
        return try await api.getConversationThread(conversation, after: receipt)
    }

    // MARK: Consultation

    /// Opens a new consultation and returns its id.
    public func startConsultation() async throws -> CadenciaAPI.ConsultationId {
        let id = BackendID.newConsultation(athlete: athleteId)
        _ = try await send { try await api.startConsultation(id, commandId: $0) }
        return id
    }

    public func recordQuestion(_ text: String, model: String, in consultation: CadenciaAPI.ConsultationId) async throws -> CadenciaAPI.ConsultationViewState? {
        let input = try CadenciaAPI.RecordCoachQuestionInput(text: .init(fitting: text), model: .init(model), interpretedOn: Self.device)
        let receipt = try await send { try await api.recordCoachQuestion(consultation, input, commandId: $0) }
        return try await api.getConsultationView(consultation, after: receipt)
    }

    public func answer(_ text: String, in consultation: CadenciaAPI.ConsultationId) async throws -> CadenciaAPI.ConsultationViewState? {
        let input = try CadenciaAPI.AnswerQuestionInput(text: .init(text: text))
        let receipt = try await send { try await api.answerQuestion(consultation, input, commandId: $0) }
        return try await api.getConsultationView(consultation, after: receipt)
    }

    public func recordDraft(_ draft: CadenciaAPI.PlanDraft, model: String, in consultation: CadenciaAPI.ConsultationId) async throws -> CadenciaAPI.ConsultationViewState? {
        let input = try CadenciaAPI.RecordDraftInput(draft: draft, model: .init(model), interpretedOn: Self.device)
        let receipt = try await send { try await api.recordDraft(consultation, input, commandId: $0) }
        return try await api.getConsultationView(consultation, after: receipt)
    }

    /// Accepts the consultation's draft as plan `planId` and returns the consultation once Planning answered:
    /// `created`, or `open` again with the reason it refused the plan. Still `accepted` if it did not answer
    /// within `answerTimeout`.
    public func acceptDraft(planId: CadenciaAPI.PlanId, in consultation: CadenciaAPI.ConsultationId) async throws -> CadenciaAPI.ConsultationViewState? {
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
        let input = try CadenciaAPI.RecordProfileInput(report: .init(report), model: .init(report.model), interpretedOn: Self.device)
        let receipt = try await send { try await api.recordProfile(athleteId, input, commandId: $0) }
        return try await api.getRiderProfileCard(athleteId, after: receipt)
    }

    // MARK: Plan changes that need no AI

    public func moveSession(_ sessionId: CadenciaAPI.SessionId, to day: Day, plan planId: CadenciaAPI.PlanId) async throws -> CadenciaAPI.CurrentPlanState? {
        let receipt = try await send { try await api.moveSession(planId, .init(sessionId: sessionId, toDay: .init(day)), commandId: $0) }
        return try await api.getCurrentPlan(athleteId, after: receipt)
    }

    public func recordDayRequirement(_ instructions: String, maxMinutes: Int?, on day: Day, plan planId: CadenciaAPI.PlanId) async throws -> CadenciaAPI.CurrentPlanState? {
        let input = try CadenciaAPI.DayRequirement(day: .init(day), instructions: .init(fitting: instructions),
                                                   maxMinutes: maxMinutes.map { try .init($0) })
        let receipt = try await send { try await api.recordDayRequirement(planId, input, commandId: $0) }
        return try await api.getCurrentPlan(athleteId, after: receipt)
    }

    /// Retires the plan as of `today`, the athlete's local day: the plan withdraws its sessions from that day on.
    public func retirePlan(_ planId: CadenciaAPI.PlanId, today: Day) async throws -> CadenciaAPI.CurrentPlanState? {
        let receipt = try await send { try await api.retirePlan(planId, .init(today: .init(today)), commandId: $0) }
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
