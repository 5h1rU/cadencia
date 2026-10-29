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

/// Interprets free-form athlete input (voice transcript or text) into a structured intent.
public protocol CoachEngine: Sendable {
    func interpret(_ utterance: String, context: CoachContext) async throws -> CoachIntent
}

// MARK: - Heuristic (offline) coach

/// Pattern-based interpreter that handles the common cases without a network: an event on a weekday with
/// a distance, limited time on a day, and how the legs feel. Spanish and English.
public struct HeuristicCoach: CoachEngine {
    public init() {}

    public func interpret(_ utterance: String, context: CoachContext) async throws -> CoachIntent {
        Self.parse(utterance, today: context.today)
    }

    static let weekdays: [(names: [String], weekday: Int)] = [
        (["domingo", "sunday"], 1), (["lunes", "monday"], 2), (["martes", "tuesday"], 3), (["miércoles", "miercoles", "wednesday"], 4),
        (["jueves", "thursday"], 5), (["viernes", "friday"], 6), (["sábado", "sabado", "saturday"], 7),
    ]

    public static func parse(_ text: String, today: Day) -> CoachIntent {
        let lower = text.lowercased()
        let sentences = lower.split(whereSeparator: { ".;!?\n".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }
        var intent = CoachIntent()

        for sentence in sentences where !sentence.isEmpty {
            let day = sentences.count == 1 || sentence.contains("mañana") || sentence.contains("tomorrow") || weekdayMentioned(sentence) != nil
                ? resolveDay(in: sentence, today: today) : nil
            let km = firstNumber(before: ["km", "kilómetros", "kilometros", "kilometers"], in: sentence)
            let minutes = firstNumber(before: ["min", "minutos", "minutes"], in: sentence)
                ?? firstNumber(before: ["hora", "horas", "hour", "hours", "h "], in: sentence).map { $0 * 60 }

            let mentionsEvent = ["salida", "carrera", "fondo", "ride", "race", "event", "evento", "grupo", "group"].contains { sentence.contains($0) }
            if mentionsEvent, let day, km != nil || sentence.contains("carrera") || sentence.contains("race") || sentence.contains("salida") {
                let name: String
                if sentence.contains("carrera") || sentence.contains("race") { name = km.map { "Race \(Int($0)) km" } ?? "Race" }
                else { name = km.map { "Group ride \(Int($0)) km" } ?? "Group ride" }
                let isRace = sentence.contains("carrera") || sentence.contains("race")
                intent.event = TrainingEvent(name: name, day: day, distanceKm: km, priority: .a, objective: objective(in: lower), isRace: isRace)
                continue
            }

            let limited = ["solo tengo", "sólo tengo", "only have", "tengo solo", "solamente", "only"].contains { sentence.contains($0) }
            if let day, let minutes, limited || sentence.contains("min") || sentence.contains("hora") || sentence.contains("hour") {
                intent.constraints.append(.init(day: day, maxMinutes: Int(minutes)))
                continue
            }

            let unavailable = ["no puedo", "can't", "cannot", "no voy a poder", "descanso", "day off", "libre"].contains { sentence.contains($0) }
            if let day, unavailable {
                intent.constraints.append(.init(day: day, unavailable: true))
                continue
            }

            if ["pesad", "cansad", "heavy", "tired", "fatigad", "cargad", "exhausted"].contains(where: { sentence.contains($0) }) {
                intent.feeling = .heavy
            } else if ["fresco", "fresh", "bien recuperado", "con ganas", "feel great"].contains(where: { sentence.contains($0) }) {
                intent.feeling = .fresh
            }
        }

        if intent.isEmpty {
            intent.needsClarification = ["I could not find a date, a distance or a time limit. Tell me which day and what changes."]
            intent.reply = "Tell me the day and what changes (an event, less time, how you feel) and I will adjust the week."
        } else {
            intent.reply = Self.reply(for: intent)
        }
        return intent
    }

    /// The objective is usually in its own sentence ("Quiero llegar fresco"), so look at the whole note.
    static func objective(in text: String) -> String {
        if text.contains("fresco") || text.contains("fresh") { return "arrive fresh" }
        if text.contains("fuerte") || text.contains("strong") || text.contains("hard") { return "finish strong" }
        return ""
    }

    static func reply(for intent: CoachIntent) -> String {
        var parts: [String] = []
        if let e = intent.event { parts.append("\(e.name) on \(e.day.iso) will be the priority. I will adjust the week so you arrive with margin.") }
        for c in intent.constraints {
            if c.unavailable { parts.append("\(c.day.iso) stays free.") }
            else if let m = c.maxMinutes { parts.append("\(c.day.iso) is capped at \(m) min.") }
        }
        if intent.feeling == .heavy { parts.append("Heavy legs noted: today stays easy.") }
        return parts.joined(separator: " ")
    }

    static func weekdayMentioned(_ s: String) -> Int? {
        for entry in weekdays where entry.names.contains(where: { s.contains($0) }) { return entry.weekday }
        return nil
    }

    /// "mañana"/"tomorrow", "hoy"/"today", or the next occurrence of a weekday name (today counts as "this" weekday).
    static func resolveDay(in s: String, today: Day) -> Day? {
        if s.contains("pasado mañana") || s.contains("day after tomorrow") { return today.adding(days: 2) }
        if s.contains("mañana") || s.contains("tomorrow") { return today.adding(days: 1) }
        if s.contains("hoy") || s.contains("today") { return today }
        guard let wd = weekdayMentioned(s) else { return nil }
        let delta = (wd - today.weekday() + 7) % 7
        return today.adding(days: delta)
    }

    static func firstNumber(before units: [String], in s: String) -> Double? {
        let tokens = s.replacingOccurrences(of: ",", with: ".").split(separator: " ").map(String.init)
        for (i, token) in tokens.enumerated() {
            for unit in units {
                let u = unit.trimmingCharacters(in: .whitespaces)
                if token.hasSuffix(u), let n = Double(token.dropLast(u.count)) { return n }
                if token == u || token.hasPrefix(u), i > 0, let n = Double(tokens[i - 1]) { return n }
            }
        }
        return nil
    }
}

// MARK: - LLM coach

/// Coach backed by any OpenAI-compatible chat-completions endpoint (OpenAI, Azure, a local server…).
/// The model is asked for strict JSON matching `CoachIntent`'s fields; nothing else from the reply is used.
public struct LLMCoach: CoachEngine {
    public var transport: any HTTPTransport
    public var endpoint: URL          // e.g. https://api.openai.com/v1/chat/completions
    public var apiKey: String
    public var model: String
    public var fallback: any CoachEngine

    public static let defaultModel = "gpt-5.6-sol"

    public init(transport: any HTTPTransport, endpoint: URL, apiKey: String, model: String = LLMCoach.defaultModel, fallback: any CoachEngine = HeuristicCoach()) {
        self.transport = transport
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.model = model
        self.fallback = fallback
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
        You are the coach inside Cadencia, a cycling training app. Interpret what the athlete says and answer ONLY with a JSON object:
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

    public func interpret(_ utterance: String, context: CoachContext) async throws -> CoachIntent {
        // No `temperature`: reasoning models (GPT-5.x / GPT-6 / o-series) reject it. `developer` is the
        // instruction role those models expect; older chat models accept it too.
        let body: [String: Any] = [
            "model": model,
            "response_format": ["type": "json_object"],
            "messages": [
                ["role": "developer", "content": Self.systemPrompt(context: context)],
                ["role": "user", "content": utterance],
            ],
        ]
        let request = HTTPRequest(method: .post, url: endpoint,
                                  headers: ["Authorization": "Bearer \(apiKey)", "Content-Type": "application/json"],
                                  body: try JSONSerialization.data(withJSONObject: body))
        let response: HTTPResponse
        do {
            response = try await transport.send(request)
        } catch {
            return try await fallback.interpret(utterance, context: context)
        }
        guard response.isSuccess else { return try await fallback.interpret(utterance, context: context) }

        struct Completion: Decodable {
            struct Choice: Decodable { struct Message: Decodable { let content: String }; let message: Message }
            let choices: [Choice]
        }
        guard let content = try? JSONDecoder().decode(Completion.self, from: response.body).choices.first?.message.content,
              let wire = try? JSONDecoder().decode(Wire.self, from: Data(content.utf8)) else {
            return try await fallback.interpret(utterance, context: context)
        }
        return Self.intent(from: wire)
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
