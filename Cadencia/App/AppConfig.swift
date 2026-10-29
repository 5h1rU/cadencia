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
    /// Only until the account's model list has loaded once; Settings then switches to a listed model.
    static let defaultLLMModel = LLMCoach.defaultModel

    static let intervalsSettingsURL = URL(string: "https://intervals.icu/settings")!
}
