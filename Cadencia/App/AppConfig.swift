import Foundation
import CadenciaCore

/// Build-time configuration. Nothing secret lives here: Cadencia's server holds the Intervals.icu OAuth
/// client, and LLM keys are entered by the user and stored in the Keychain.
enum AppConfig {
    /// Cadencia's backend (`web/`): the web app's Worker, which forwards `/auth/*` and `/v1/*` to the API and
    /// is the origin Intervals.icu returns to after the athlete signs in.
    static let backendURL = URL(string: "https://cadencia-cadenciaapp-prod-6ki44jvdsgk3fzku.yo-617.workers.dev")!

    static let defaultLLMEndpoint = URL(string: "https://api.openai.com/v1/chat/completions")!
    /// Only until the account's model list has loaded once; Settings then switches to a listed model.
    static let defaultLLMModel = LLMCoach.defaultModel
}
