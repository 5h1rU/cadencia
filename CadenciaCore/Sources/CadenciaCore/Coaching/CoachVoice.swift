import Foundation

/// The coach's spoken voice through OpenAI text-to-speech. Only reachable with an API key: the ChatGPT
/// plan sign-in is limited to `POST /v1/responses`, so on that path the app falls back to the phone's voice.
public enum CoachVoice {
    public static let model = "gpt-4o-mini-tts"

    /// Built-in voices that suit a coach. The first is the default.
    public struct Option: Identifiable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var note: String
    }

    public static let options: [Option] = [
        Option(id: "ash", name: "Ash", note: "Confident, warm, energetic"),
        Option(id: "cedar", name: "Cedar", note: "Natural, grounded"),
        Option(id: "marin", name: "Marin", note: "Natural, bright"),
        Option(id: "verse", name: "Verse", note: "Dynamic, expressive"),
        Option(id: "coral", name: "Coral", note: "Warm, clear"),
        Option(id: "echo", name: "Echo", note: "Steady, direct"),
        Option(id: "sage", name: "Sage", note: "Calm, composed"),
        Option(id: "onyx", name: "Onyx", note: "Deep, authoritative"),
    ]

    public static let defaultVoice = options[0].id

    /// How the line should be delivered. The model reads this, not the athlete.
    public static func instructions(locale: String) -> String {
        var s = """
        You are a road-cycling coach calling to your rider from the team car during a hard session. Energetic, confident and warm, \
        like a sports broadcaster who genuinely cares. Quick pace, crisp consonants, short pauses between sentences; lift the energy \
        on praise and encouragement, drop to calm and steady on cautions. Never flat, never shouting.
        """
        if locale.hasPrefix("es") { s += " Speak natural, neutral Latin American Spanish." }
        return s
    }

    /// `/v1/audio/speech` next to the configured chat endpoint (`…/v1/chat/completions` → `…/v1/audio/speech`).
    /// Nil when the endpoint is not a `/v1` OpenAI-style API.
    public static func speechURL(nextTo endpoint: URL) -> URL? {
        guard let range = endpoint.path.range(of: "/v1", options: .backwards) else { return nil }
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.path = String(endpoint.path[..<range.upperBound]) + "/audio/speech"
        components?.query = nil
        return components?.url
    }

    public static func request(text: String, voice: String, locale: String, endpoint: URL, apiKey: String) -> HTTPRequest? {
        guard let url = speechURL(nextTo: endpoint) else { return nil }
        let body: [String: Any] = [
            "model": model,
            "input": text,
            "voice": voice,
            "instructions": instructions(locale: locale),
            "response_format": "mp3",
            "speed": 1.05,
        ]
        let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return HTTPRequest(method: .post, url: url,
                           headers: ["Authorization": "Bearer \(apiKey)", "Content-Type": "application/json", "Accept": "audio/mpeg"],
                           body: data)
    }
}
