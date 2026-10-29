import Foundation
import AuthenticationServices
import Network
import UIKit
import CadenciaCore

/// Runs "Sign in with ChatGPT" on the phone.
///
/// OpenAI only redirects this flow to `http://127.0.0.1:<port>/auth/callback`, so the app opens a
/// loopback HTTP listener for the duration of the sign-in, shows the OpenAI page in the system browser
/// sheet, reads the callback from the listener, answers with a small "you can close this" page and
/// dismisses the sheet. Nothing listens once the flow ends; the listener binds to 127.0.0.1 only.
@MainActor
final class ChatGPTSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    enum Failure: LocalizedError {
        case cancelled, listenerFailed, timedOut

        var errorDescription: String? {
            switch self {
            case .cancelled: return String(localized: "Sign-in was cancelled.")
            case .listenerFailed: return String(localized: "Could not open the local sign-in callback.")
            case .timedOut: return String(localized: "ChatGPT did not finish signing in. Try again.")
            }
        }
    }

    private var session: ASWebAuthenticationSession?
    private var listener: NWListener?
    private var connections: [NWConnection] = []

    /// Opens the browser sheet and returns a validated credential.
    /// - Parameters:
    ///   - clientID: the `oaiapp_…` id from a previous sign-in, or nil to register this app.
    ///   - hostID: stable per-device `urn:uuid:` string.
    ///   - forceConsent: ask for the plan scope again (`prompt=consent`).
    func signIn(clientID: String?, hostID: String, idTokenHint: String? = nil, loginHint: String? = nil, forceConsent: Bool = false,
                transport: any HTTPTransport) async throws -> ChatGPTCredential {
        let port = try await startListener()
        defer { stopListener() }

        let auth = ChatGPTAuth()
        let attempt = ChatGPTAuth.Attempt(clientID: clientID, hostID: hostID, redirectURI: ChatGPTAuth.redirectURI(port: port),
                                          idTokenHint: idTokenHint, loginHint: loginHint, forceConsent: forceConsent)
        let callbackURL = try await presentAndWait(authorizationURL: auth.authorizationURL(attempt))
        let callback = try auth.parseCallback(callbackURL, for: attempt)
        let token = try await auth.exchange(callback, attempt: attempt, transport: transport)
        return try auth.credential(from: token, callback: callback, attempt: attempt)
    }

    // MARK: Browser sheet

    /// Shows the browser and races it against the loopback callback: whichever finishes first wins.
    private func presentAndWait(authorizationURL: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            var finished = false
            func finish(_ result: Result<URL, Error>) {
                guard !finished else { return }
                finished = true
                continuation.resume(with: result)
            }

            callbackHandler = { url in
                finish(.success(url))
                // Closing the sheet after the callback arrived reports `canceledLogin`; that is expected.
                self.session?.cancel()
            }

            // The scheme is never hit (OpenAI redirects to the loopback listener); it only satisfies the API.
            let session = ASWebAuthenticationSession(url: authorizationURL, callbackURLScheme: AppConfig.intervalsOAuthCallbackScheme) { url, error in
                if let url { finish(.success(url)); return }
                if let e = error as? ASWebAuthenticationSessionError, e.code == .canceledLogin { finish(.failure(Failure.cancelled)); return }
                finish(.failure(error ?? Failure.cancelled))
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            session.start()
        }
    }

    private var callbackHandler: ((URL) -> Void)?

    // MARK: Loopback listener

    private func startListener() async throws -> UInt16 {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        params.allowLocalEndpointReuse = true
        let listener: NWListener
        do { listener = try NWListener(using: params) } catch { throw Failure.listenerFailed }
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            var resumed = false
            listener.stateUpdateHandler = { state in
                Task { @MainActor in
                    guard !resumed else { return }
                    switch state {
                    case .ready:
                        if let port = listener.port?.rawValue { resumed = true; continuation.resume(returning: port) }
                        else { resumed = true; continuation.resume(throwing: Failure.listenerFailed) }
                    case .failed, .cancelled:
                        resumed = true
                        continuation.resume(throwing: Failure.listenerFailed)
                    default: break
                    }
                }
            }
            listener.start(queue: .main)
        }
    }

    private func stopListener() {
        listener?.cancel()
        listener = nil
        connections.forEach { $0.cancel() }
        connections = []
        callbackHandler = nil
    }

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: .main)
        var buffer = Data()
        func readMore() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let data { buffer.append(data) }
                    if let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
                        let head = String(decoding: buffer[..<range.lowerBound], as: UTF8.self)
                        self.handle(requestHead: head, on: connection)
                    } else if isComplete || error != nil || buffer.count > 64 * 1024 {
                        connection.cancel()
                    } else {
                        readMore()
                    }
                }
            }
        }
        readMore()
    }

    private func handle(requestHead: String, on connection: NWConnection) {
        // "GET /auth/callback?code=…&state=… HTTP/1.1"
        let target = requestHead.split(separator: "\r\n").first?.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        let url = URL(string: "http://127.0.0.1\(target)")
        let isCallback = url?.path == ChatGPTAuth.callbackPath

        let title = isCallback ? String(localized: "Signed in to Cadencia") : String(localized: "Not found")
        let body = isCallback ? String(localized: "You can close this window and return to the app.") : ""
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>\(title)</title><style>body{font-family:-apple-system,system-ui;text-align:center;padding:15vh 24px;color:#111}</style></head>
        <body><h1>\(title)</h1><p>\(body)</p></body></html>
        """
        let status = isCallback ? "200 OK" : "404 Not Found"
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })

        if isCallback, let url { callbackHandler?(url) }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            return scenes.flatMap(\.windows).first { $0.isKeyWindow } ?? ASPresentationAnchor()
        }
    }
}

/// Athlete-facing wording for the protocol failures the core reports.
extension ChatGPTAuth.Failure: @retroactive LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .accessDenied: return String(localized: "You declined the ChatGPT sign-in.")
        case .stateMismatch, .missingCode, .missingClientID, .clientIDMismatch:
            return String(localized: "The sign-in response did not match this request. Try again.")
        case .invalidIDToken: return String(localized: "ChatGPT returned an identity token this app could not verify.")
        case .tokenEndpoint(let status, _): return String(localized: "OpenAI rejected the sign-in (HTTP \(status)).")
        case .refreshTokenUnusable: return String(localized: "The saved ChatGPT sign-in has expired. Sign in again.")
        }
    }
}
