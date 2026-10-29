import Foundation
import CadenciaCore

/// Build-time configuration. Nothing secret lives here: the OAuth client is a public client (PKCE),
/// and LLM keys are entered by the user and stored in the Keychain.
enum AppConfig {
    /// Client id issued by Intervals.icu when the Cadencia app is registered
    /// (Settings → Developer → Apps). Empty until that registration exists; the API key path works regardless.
    static let intervalsOAuthClientID = ""
    static let intervalsOAuthRedirectURI = "cadencia://oauth"
    static let intervalsOAuthCallbackScheme = "cadencia"

    static var intervalsOAuth: IntervalsOAuth? {
        guard !intervalsOAuthClientID.isEmpty else { return nil }
        return IntervalsOAuth(clientID: intervalsOAuthClientID, redirectURI: intervalsOAuthRedirectURI)
    }

    static let defaultLLMEndpoint = URL(string: "https://api.openai.com/v1/chat/completions")!
    static let defaultLLMModel = LLMCoach.defaultModel

    /// OpenAI models offered in Settings → Coach (Oct 2026). Any other id can still be typed.
    static let llmModelPresets: [(id: String, note: String)] = [
        ("gpt-6-astra", "Most capable reasoning"),
        ("gpt-5.6-sol", "Balanced, o1's successor"),
        ("gpt-5.6-terra", "Lower cost"),
        ("gpt-5.6-luna", "Fastest, cheapest"),
    ]

    static let intervalsSettingsURL = URL(string: "https://intervals.icu/settings")!
}
