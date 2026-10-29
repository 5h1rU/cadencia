import Foundation
import AuthenticationServices
import UIKit
import CadenciaCore

/// Runs the Intervals.icu authorization-code + PKCE flow in the system browser sheet.
/// The code verifier never leaves the device; no client secret exists in the app.
@MainActor
final class OAuthSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    enum Failure: LocalizedError {
        case cancelled, stateMismatch, missingCode, notConfigured

        var errorDescription: String? {
            switch self {
            case .cancelled: return String(localized: "Sign-in was cancelled.")
            case .stateMismatch: return String(localized: "The sign-in response did not match this request.")
            case .missingCode: return String(localized: "Intervals did not return an authorization code.")
            case .notConfigured: return String(localized: "OAuth is not configured for this build. Use an API key.")
            }
        }
    }

    private var session: ASWebAuthenticationSession?

    func signIn(transport: any HTTPTransport) async throws -> IntervalsOAuth.TokenResponse {
        guard let oauth = AppConfig.intervalsOAuth else { throw Failure.notConfigured }
        let pkce = IntervalsOAuth.makePKCE()
        let state = UUID().uuidString
        let url = oauth.authorizationURL(pkce: pkce, state: state)

        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: AppConfig.intervalsOAuthCallbackScheme) { url, error in
                if let callbackURL = url {
                    continuation.resume(returning: callbackURL)
                } else if let sessionError = error as? ASWebAuthenticationSessionError, sessionError.code == .canceledLogin {
                    continuation.resume(throwing: Failure.cancelled)
                } else {
                    continuation.resume(throwing: error ?? Failure.cancelled)
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            session.start()
        }

        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard items.first(where: { $0.name == "state" })?.value == state else { throw Failure.stateMismatch }
        guard let code = items.first(where: { $0.name == "code" })?.value else { throw Failure.missingCode }
        return try await oauth.exchange(code: code, pkce: pkce, transport: transport)
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            return scenes.flatMap(\.windows).first { $0.isKeyWindow } ?? ASPresentationAnchor()
        }
    }
}
