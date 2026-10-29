import Foundation

/// Everything the coach may look at when interpreting what the athlete said.
public struct CoachContext: Sendable {
    public var today: Day
    public var locale: String                     // "es" or "en"
    public var readiness: Readiness?
    public var plan: TrainingPlan?
    public var recentActivities: [ActivitySummary]
    public var ftp: Int?

    public init(today: Day, locale: String = "es", readiness: Readiness? = nil, plan: TrainingPlan? = nil,
                recentActivities: [ActivitySummary] = [], ftp: Int? = nil) {
        self.today = today
        self.locale = locale
        self.readiness = readiness
        self.plan = plan
        self.recentActivities = recentActivities
        self.ftp = ftp
    }
}

public enum LLMCoachError: Error, Equatable, Sendable {
    /// ChatGPT plan: weekly/app limit reached. Point at chatgpt.com/settings/usage.
    case usageLimitReached
    /// ChatGPT plan: this account or workspace cannot share usage with apps.
    case notEligible
    /// Token rejected (revoked in ChatGPT settings, or refresh failed): sign in again.
    case unauthorized
}

/// Coach backed by a language model. Two ways to pay for it:
/// - `.apiKey`: any OpenAI-compatible chat-completions endpoint (OpenAI, Azure, a local server…).
/// - `.chatGPTPlan`: the athlete's own ChatGPT subscription through Sign in with ChatGPT, which
///   only speaks the Responses API with `store:false, stream:true`.
/// Either way the model is asked for strict JSON matching `CoachIntent`'s fields; nothing else is used.
public struct LLMCoach: Sendable {
    public enum Backend: Sendable, Equatable {
        case apiKey(endpoint: URL, key: String)
        case chatGPTPlan(accessToken: String)
    }

    public var transport: any HTTPTransport
    public var backend: Backend
    public var model: String

    public static let defaultModel = "gpt-5.6-sol"
    public static let responsesURL = URL(string: "https://api.openai.com/v1/responses")!
    public static let modelsURL = URL(string: "https://api.openai.com/v1/models")!

    public init(transport: any HTTPTransport, backend: Backend, model: String = LLMCoach.defaultModel) {
        self.transport = transport
        self.backend = backend
        self.model = model
    }

    public init(transport: any HTTPTransport, endpoint: URL, apiKey: String, model: String = LLMCoach.defaultModel) {
        self.init(transport: transport, backend: .apiKey(endpoint: endpoint, key: apiKey), model: model)
    }

    struct Wire: Codable {
        struct Event: Codable { var name: String; var day: String; var distanceKm: Double?; var priority: String?; var objective: String? }
        struct Constraint: Codable { var day: String; var maxMinutes: Int?; var unavailable: Bool? }
        var event: Event?
        var constraints: [Constraint]?
        var feeling: String?
        var goal: String?
        var reply: String
        var needsClarification: [String]?
    }

    public static func systemPrompt(context: CoachContext) -> String {
        var s = """
        You are the head coach inside Cadencia, a cycling training app: an expert road-cycling coach who knows this athlete's \
        plan and recovery. Interpret what the athlete says, acknowledge it the way a coach would, and answer ONLY with a JSON object:
        {"event": {"name": string, "day": "YYYY-MM-DD", "distanceKm": number|null, "priority": "a"|"b"|"c", "objective": string} | null,
         "constraints": [{"day": "YYYY-MM-DD", "maxMinutes": number|null, "unavailable": boolean}],
         "feeling": "fresh"|"ok"|"heavy"|null,
         "goal": "climbing"|"ftp"|"durability"|"endurance"|"strength"|"event"|null,
         "reply": string (1-2 sentences, in the athlete's language: \(context.locale)),
         "needsClarification": [string]}
        Today is \(context.today.iso) (weekday \(context.today.weekday()), 1=Sunday). Resolve relative dates to absolute dates.
        Never invent an event or a date the athlete did not mention. If something is ambiguous, list it in needsClarification.
        """
        if let r = context.readiness { s += "\nReadiness today: \(r.level.rawValue) (\(r.score)/100)." }
        if let p = context.plan { s += "\nActive plan: \(p.title), \(p.startDay.iso) to \(p.endDay.iso)." }
        if let ftp = context.ftp { s += "\nWorking FTP: \(ftp) W." }
        return s
    }

    /// Interprets what the athlete said (voice transcript or text) into a structured intent.
    public func interpret(_ utterance: String, context: CoachContext) async throws -> CoachIntent {
        let content = try await complete(instructions: Self.systemPrompt(context: context), userText: utterance)
        guard let wire = try? JSONDecoder().decode(Wire.self, from: Data(content.utf8)) else { throw CompletionError.unusableAnswer }
        return Self.intent(from: wire)
    }

    /// Why a completion produced nothing usable. Plan errors (`LLMCoachError`) are thrown as-is instead.
    public enum CompletionError: Error, Equatable, Sendable {
        case transport(String)
        case httpStatus(Int)
        case emptyResponse
        case unusableAnswer
    }

    /// One JSON-mode completion on whichever backend is configured. Returns the model's text.
    public func complete(instructions: String, userText: String) async throws -> String {
        let request = try self.request(instructions: instructions, userText: userText)
        let response: HTTPResponse
        do {
            response = try await transport.send(request)
        } catch {
            throw CompletionError.transport(String(describing: error))
        }
        if case .chatGPTPlan = backend, let error = Self.planError(status: response.status, body: response.body) { throw error }
        guard response.isSuccess else { throw CompletionError.httpStatus(response.status) }

        let content: String?
        switch backend {
        case .apiKey: content = Self.chatCompletionText(response.body)
        case .chatGPTPlan:
            do { content = try Self.responsesText(sse: response.body) } catch let error as LLMCoachError { throw error } catch { content = nil }
        }
        guard let content, !content.isEmpty else { throw CompletionError.emptyResponse }
        return content
    }

    /// The full daily decision: readiness, today's session, the week's shape. Throws on plan errors,
    /// transport failures and on any answer that fails `DailyPrescription.parse`'s safety checks.
    public func prescribe(brief: CoachBrief, now: Date = Date()) async throws -> DailyPrescription {
        guard let today = Day(iso: brief.today) else { throw DailyPrescription.ValidationError.badDay(brief.today) }
        let content = try await complete(instructions: AICoachPrompt.instructions(locale: brief.locale),
                                         userText: try AICoachPrompt.userMessage(brief))
        return try DailyPrescription.parse(Data(content.utf8), measured: brief.measured, today: today,
                                           availableMinutes: brief.availableMinutes, model: model, now: now)
    }

    /// The outgoing request for either backend. No `temperature`: reasoning models (GPT-5.x / GPT-6)
    /// reject it, and the ChatGPT-plan route rejects it outright. `developer` is the instruction role.
    func request(utterance: String, context: CoachContext) throws -> HTTPRequest {
        try request(instructions: Self.systemPrompt(context: context), userText: utterance)
    }

    func request(instructions prompt: String, userText utterance: String) throws -> HTTPRequest {
        switch backend {
        case .apiKey(let endpoint, let key):
            let body: [String: Any] = [
                "model": model,
                "response_format": ["type": "json_object"],
                "messages": [
                    ["role": "developer", "content": prompt],
                    ["role": "user", "content": utterance],
                ],
            ]
            return HTTPRequest(method: .post, url: endpoint,
                               headers: ["Authorization": "Bearer \(key)", "Content-Type": "application/json"],
                               body: try JSONSerialization.data(withJSONObject: body))
        case .chatGPTPlan(let token):
            // Required by the plan-usage route: store:false, stream:true, instructions instead of a system item.
            let body: [String: Any] = [
                "model": model,
                "instructions": prompt,
                "input": [["role": "user", "content": utterance]],
                "text": ["format": ["type": "json_object"]],
                "store": false,
                "stream": true,
            ]
            return HTTPRequest(method: .post, url: Self.responsesURL,
                               headers: ["Authorization": "Bearer \(token)", "Content-Type": "application/json", "Accept": "text/event-stream"],
                               body: try JSONSerialization.data(withJSONObject: body))
        }
    }

    static func chatCompletionText(_ data: Data) -> String? {
        struct Completion: Decodable {
            struct Choice: Decodable { struct Message: Decodable { let content: String }; let message: Message }
            let choices: [Choice]
        }
        return try? JSONDecoder().decode(Completion.self, from: data).choices.first?.message.content
    }

    /// Reassembles the model's text from a Responses SSE body. The body is read whole (the transport
    /// is not streaming); only `response.completed` counts as success, as the plan-usage docs require.
    static func responsesText(sse data: Data) throws -> String {
        var deltas = ""
        var completedText: String?
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard payload != "[DONE]", let json = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { continue }
            switch json["type"] as? String {
            case "response.output_text.delta":
                deltas += json["delta"] as? String ?? ""
            case "response.completed":
                let output = ((json["response"] as? [String: Any])?["output"] as? [[String: Any]]) ?? []
                let texts = output.flatMap { ($0["content"] as? [[String: Any]]) ?? [] }.compactMap { $0["text"] as? String }
                completedText = texts.isEmpty ? deltas : texts.joined()
            case "response.failed", "error":
                let error = (json["response"] as? [String: Any])?["error"] as? [String: Any] ?? json["error"] as? [String: Any] ?? json
                let code = error["code"] as? String
                if let mapped = planError(code: code) { throw mapped }
                throw ResponsesFailure(code: code ?? "unknown")
            default: break
            }
        }
        guard let completedText else { throw ResponsesFailure(code: "incomplete") }
        return completedText
    }

    struct ResponsesFailure: Error { var code: String }

    /// Plan-usage errors that need the athlete, mapped from HTTP status + Responses error code.
    static func planError(status: Int, body: Data) -> LLMCoachError? {
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let code = (json?["error"] as? [String: Any])?["code"] as? String
        if let mapped = planError(code: code) { return mapped }
        switch status {
        case 401: return .unauthorized
        case 403: return .notEligible
        case 429: return .usageLimitReached
        default: return nil
        }
    }

    static func planError(code: String?) -> LLMCoachError? {
        switch code {
        case "subscription_sharing_usage_limit_exceeded": return .usageLimitReached
        case "subscription_sharing_user_not_eligible", "chatpass_v2_scope_not_authorized", "chatpass_v2_invalid_authorization_context": return .notEligible
        case "subscription_sharing_invalid_user": return .unauthorized
        default: return nil
        }
    }

    public struct Model: Identifiable, Equatable, Sendable {
        public var id: String
        public var name: String
        public init(id: String, name: String) { self.id = id; self.name = name }
    }

    /// Model catalog for the signed-in ChatGPT account (`{models:[{slug, display_name, visibility}]}`),
    /// or the API-key catalog (`{data:[{id}]}`), in server order.
    public func listModels() async throws -> [Model] {
        let auth: String
        switch backend {
        case .apiKey(_, let key): auth = key
        case .chatGPTPlan(let token): auth = token
        }
        let response = try await transport.send(HTTPRequest(method: .get, url: Self.modelsURL, headers: ["Authorization": "Bearer \(auth)"]))
        if case .chatGPTPlan = backend, let error = Self.planError(status: response.status, body: response.body) { throw error }
        guard response.isSuccess, let json = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any] else {
            throw HTTPError.status(response.status, String(decoding: response.body, as: UTF8.self))
        }
        if let models = json["models"] as? [[String: Any]] {
            return models.filter { ($0["visibility"] as? String ?? "list") == "list" }
                .compactMap { m in (m["slug"] as? String).map { Model(id: $0, name: m["display_name"] as? String ?? $0) } }
        }
        return ((json["data"] as? [[String: Any]]) ?? []).compactMap { m in (m["id"] as? String).map { Model(id: $0, name: $0) } }
    }

    static func intent(from w: Wire) -> CoachIntent {
        var intent = CoachIntent(reply: w.reply, needsClarification: w.needsClarification ?? [])
        if let e = w.event, let day = Day(iso: e.day) {
            let priority = TrainingEvent.Priority(rawValue: e.priority ?? "a") ?? .a
            intent.event = TrainingEvent(name: e.name, day: day, distanceKm: e.distanceKm, priority: priority, objective: e.objective ?? "")
        }
        intent.constraints = (w.constraints ?? []).compactMap { c in
            Day(iso: c.day).map { CoachIntent.DayConstraint(day: $0, maxMinutes: c.maxMinutes, unavailable: c.unavailable ?? false) }
        }
        intent.feeling = w.feeling.flatMap(SubjectiveFeedback.Legs.init(rawValue:))
        intent.goal = w.goal.flatMap(GoalKind.init(rawValue:))
        return intent
    }
}
