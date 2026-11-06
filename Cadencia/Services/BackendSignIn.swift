import Foundation
import AuthenticationServices
import UIKit
import CadenciaCore

/// What the app keeps of a Cadencia sign-in, in the Keychain: the session token it sends as
/// `Authorization: Bearer`, and the Intervals.icu athlete it belongs to.
struct BackendSession: Codable, Equatable {
    var token: String
    var athleteID: String
}

/// Signs in to Cadencia's backend: the server sends the athlete to Intervals.icu, then back to
/// `cadencia://auth/callback?handoff=…`; the one-minute handoff is exchanged for a session.
@MainActor
final class BackendSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    enum Failure: LocalizedError {
        case cancelled, missingHandoff, notConfigured

        var errorDescription: String? {
            switch self {
            case .cancelled: return String(localized: "Sign-in was cancelled.")
            case .missingHandoff: return String(localized: "Cadencia did not complete the sign-in. Try again.")
            case .notConfigured: return String(localized: "This build has no Cadencia server configured.")
            }
        }
    }

    private var session: ASWebAuthenticationSession?

    func signIn(transport: any HTTPTransport) async throws -> BackendSession {
        guard let baseURL = AppConfig.backendURL else { throw Failure.notConfigured }
        var api = CadenciaAPI(baseURL: baseURL, transport: transport)
        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: api.signInURL, callbackURLScheme: CadenciaAPI.callbackScheme) { url, error in
                if let url {
                    continuation.resume(returning: url)
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
        guard let handoff = CadenciaAPI.handoff(from: callback) else { throw Failure.missingHandoff }
        let token = try await api.exchange(handoff: handoff)
        api.sessionToken = token
        return BackendSession(token: token, athleteID: try await api.signedInAthlete())
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            return scenes.flatMap(\.windows).first { $0.isKeyWindow } ?? ASPresentationAnchor()
        }
    }
}
