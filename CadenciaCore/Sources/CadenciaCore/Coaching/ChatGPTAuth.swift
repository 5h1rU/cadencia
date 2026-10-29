import Foundation

/// A ChatGPT account connected through Sign in with ChatGPT, with permission to use the athlete's
/// ChatGPT plan for the coach. One record per issued client; stored in the Keychain by the app.
/// Shape follows OpenAI's documented credential record (developers.openai.com/siwc).
public struct ChatGPTCredential: Codable, Equatable, Sendable {
    public var clientID: String          // issued `oaiapp_…`, never `dynamic_agent_client`
    public var hostID: String            // this device's stable `ext_agent_host_id`
    public var subject: String           // validated ID-token `sub`
    public var email: String?
    public var idToken: String
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date
    public var scopes: [String]
    public var savedAt: Date

    public init(clientID: String, hostID: String, subject: String, email: String?, idToken: String, accessToken: String,
                refreshToken: String?, expiresAt: Date, scopes: [String], savedAt: Date = Date()) {
        self.clientID = clientID
        self.hostID = hostID
        self.subject = subject
        self.email = email
        self.idToken = idToken
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scopes = scopes
        self.savedAt = savedAt
    }

    /// Consent to spend the user's ChatGPT plan. A valid sign-in without this scope cannot run inference.
    public var planUsageEnabled: Bool { scopes.contains(ChatGPTAuth.planUsageScope) }

    /// True when the access token should be refreshed before the next request (60 s of slack).
    public func needsRefresh(now: Date = Date()) -> Bool { now >= expiresAt.addingTimeInterval(-60) }
}

/// Sign in with ChatGPT for open-source / locally running clients: dynamic client registration,
/// authorization code + PKCE, refresh and revocation. No client secret exists.
public struct ChatGPTAuth: Sendable {
    public static let authorizeURL = URL(string: "https://auth.openai.com/api/accounts/authorize")!
    public static let tokenURL = URL(string: "https://auth.openai.com/api/accounts/oauth/token")!
    public static let revokeURL = URL(string: "https://auth.openai.com/api/accounts/oauth/revoke")!
    public static let discoveryURL = URL(string: "https://auth.openai.com/.well-known/openid-configuration")!
    public static let issuer = "https://auth.openai.com"
    public static let resource = "https://api.openai.com/v1"
    public static let registrationClientID = "dynamic_agent_client"
    public static let agentName = "Cadencia"
    public static let planUsageScope = "chatgpt.tokens.use.direct"
    public static let identityScopes = ["openid", "profile", "email"]
    public static let planScopes = ["offline_access", "resource.invoke", planUsageScope]
    public static let usageSettingsURL = URL(string: "https://chatgpt.com/settings/usage")!

    /// Loopback callback: OpenAI only accepts `http://127.0.0.1:<port>/auth/callback` for this flow.
    public static let callbackPath = "/auth/callback"
    public static func redirectURI(port: UInt16) -> String { "http://127.0.0.1:\(port)\(callbackPath)" }

    public enum Failure: Error, Equatable, Sendable {
        case accessDenied
        case stateMismatch
        case missingCode
        case missingClientID       // new registration callback without an issued client id
        case clientIDMismatch      // reauthorization callback named a different client
        case invalidIDToken(String)
        case tokenEndpoint(Int, String)
        case refreshTokenUnusable(String)
    }

    public init() {}

    // MARK: Authorization request

    public struct Attempt: Sendable, Equatable {
        public var clientID: String?      // nil → first-time registration
        public var hostID: String
        public var redirectURI: String
        public var pkce: PKCE
        public var state: String
        public var nonce: String
        public var idTokenHint: String?
        public var loginHint: String?
        public var forceConsent = false

        public init(clientID: String?, hostID: String, redirectURI: String, pkce: PKCE = .make(), state: String = UUID().uuidString,
                    nonce: String = UUID().uuidString, idTokenHint: String? = nil, loginHint: String? = nil, forceConsent: Bool = false) {
            self.clientID = clientID
            self.hostID = hostID
            self.redirectURI = redirectURI
            self.pkce = pkce
            self.state = state
            self.nonce = nonce
            self.idTokenHint = idTokenHint
            self.loginHint = loginHint
            self.forceConsent = forceConsent
        }
    }

    public func authorizationURL(_ a: Attempt) -> URL {
        var items: [URLQueryItem] = [
            .init(name: "client_id", value: a.clientID ?? Self.registrationClientID),
        ]
        if a.clientID == nil { items.append(.init(name: "agent_name_hint", value: Self.agentName)) }
        items += [
            .init(name: "ext_agent_host_id", value: a.hostID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: a.redirectURI),
            .init(name: "scope", value: (Self.identityScopes + Self.planScopes).joined(separator: " ")),
            .init(name: "resource", value: Self.resource),
            .init(name: "state", value: a.state),
            .init(name: "nonce", value: a.nonce),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: a.pkce.challenge),
        ]
        if let hint = a.idTokenHint { items.append(.init(name: "id_token_hint", value: hint)) }
        if let login = a.loginHint { items.append(.init(name: "login_hint", value: login)) }
        if a.forceConsent { items.append(.init(name: "prompt", value: "consent")) }
        var c = URLComponents(url: Self.authorizeURL, resolvingAgainstBaseURL: false)!
        c.queryItems = items
        return c.url!
    }

    // MARK: Callback

    public struct Callback: Equatable, Sendable {
        public var code: String
        public var clientID: String
    }

    /// Validates the loopback callback against the attempt and returns the code and the client id to exchange with.
    public func parseCallback(_ url: URL, for a: Attempt) throws -> Callback {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard value("state") == a.state else { throw Failure.stateMismatch }
        if let error = value("error") {
            throw error == "access_denied" ? Failure.accessDenied : Failure.tokenEndpoint(0, error)
        }
        guard let code = value("code"), !code.isEmpty else { throw Failure.missingCode }
        let issued = value("client_id")
        if let saved = a.clientID {
            if let issued, issued != saved { throw Failure.clientIDMismatch }
            return Callback(code: code, clientID: saved)
        }
        guard let issued, issued != Self.registrationClientID else { throw Failure.missingClientID }
        return Callback(code: code, clientID: issued)
    }

    // MARK: Token endpoint

    public struct TokenResponse: Decodable, Equatable, Sendable {
        public var access_token: String
        public var refresh_token: String?
        public var id_token: String?
        public var token_type: String?
        public var expires_in: Int?
        public var scope: String?
        public var scopes: [String] { (scope ?? "").split(separator: " ").map(String.init) }
    }

    public func exchange(_ callback: Callback, attempt a: Attempt, transport: any HTTPTransport) async throws -> TokenResponse {
        try await token(form: [
            ("grant_type", "authorization_code"),
            ("client_id", callback.clientID),
            ("code", callback.code),
            ("code_verifier", a.pkce.verifier),
            ("redirect_uri", a.redirectURI),
            ("resource", Self.resource),
        ], transport: transport)
    }

    /// Standard refresh; the reply carries a replacement refresh token that must overwrite the old one.
    public func refresh(_ c: ChatGPTCredential, transport: any HTTPTransport, now: Date = Date()) async throws -> ChatGPTCredential {
        guard let refreshToken = c.refreshToken else { throw Failure.refreshTokenUnusable("no refresh token") }
        let token: TokenResponse
        do {
            token = try await self.token(form: [
                ("grant_type", "refresh_token"),
                ("client_id", c.clientID),
                ("refresh_token", refreshToken),
                ("resource", Self.resource),
            ], transport: transport)
        } catch Failure.tokenEndpoint(let status, let body) {
            if Self.isTerminalRefreshError(body) { throw Failure.refreshTokenUnusable(body) }
            throw Failure.tokenEndpoint(status, body)
        }
        var next = c
        next.accessToken = token.access_token
        next.refreshToken = token.refresh_token ?? c.refreshToken
        if let id = token.id_token { next.idToken = id }
        next.expiresAt = now.addingTimeInterval(TimeInterval(token.expires_in ?? 3600))
        if !token.scopes.isEmpty { next.scopes = token.scopes }
        next.savedAt = now
        return next
    }

    /// Revokes the refresh token. An empty 200 is success, including for an already-invalid token.
    public func revoke(_ c: ChatGPTCredential, transport: any HTTPTransport) async throws {
        guard let refreshToken = c.refreshToken else { return }
        let request = HTTPRequest(method: .post, url: Self.revokeURL,
                                  headers: ["Content-Type": "application/x-www-form-urlencoded"],
                                  body: FormBody.encode([("token", refreshToken), ("token_type_hint", "refresh_token"), ("client_id", c.clientID)]))
        let response = try await transport.send(request)
        guard response.isSuccess else { throw Failure.tokenEndpoint(response.status, String(decoding: response.body, as: UTF8.self)) }
    }

    static let terminalRefreshCodes = ["invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired", "refresh_token_invalidated", "refresh_token_reused"]

    static func isTerminalRefreshError(_ body: String) -> Bool {
        terminalRefreshCodes.contains { body.contains($0) }
    }

    private func token(form: [(String, String)], transport: any HTTPTransport) async throws -> TokenResponse {
        let request = HTTPRequest(method: .post, url: Self.tokenURL,
                                  headers: ["Content-Type": "application/x-www-form-urlencoded", "Accept": "application/json"],
                                  body: FormBody.encode(form))
        let response = try await transport.send(request)
        guard response.isSuccess else { throw Failure.tokenEndpoint(response.status, String(decoding: response.body, as: UTF8.self)) }
        return try JSONDecoder().decode(TokenResponse.self, from: response.body)
    }

    // MARK: ID token

    /// Builds the credential after checking the ID token's claims against this attempt.
    ///
    /// The token arrives straight from the token endpoint over TLS, so (per OpenID Connect Core 3.1.3.7.6)
    /// the claims are trusted without a JWKS signature check; the app has no JOSE library and the
    /// token is never accepted from the browser redirect. Issuer, audience, expiry and nonce are enforced.
    public func credential(from token: TokenResponse, callback: Callback, attempt a: Attempt, now: Date = Date()) throws -> ChatGPTCredential {
        guard let idToken = token.id_token, let claims = Self.claims(ofJWT: idToken) else { throw Failure.invalidIDToken("missing id_token") }
        guard claims["iss"] as? String == Self.issuer else { throw Failure.invalidIDToken("issuer") }
        let audiences = (claims["aud"] as? [String]) ?? (claims["aud"] as? String).map { [$0] } ?? []
        guard audiences.contains(callback.clientID) else { throw Failure.invalidIDToken("audience") }
        guard claims["nonce"] as? String == a.nonce else { throw Failure.invalidIDToken("nonce") }
        if let exp = claims["exp"] as? Double, Date(timeIntervalSince1970: exp) < now { throw Failure.invalidIDToken("expired") }
        guard let sub = claims["sub"] as? String, !sub.isEmpty else { throw Failure.invalidIDToken("subject") }
        return ChatGPTCredential(clientID: callback.clientID, hostID: a.hostID, subject: sub, email: claims["email"] as? String,
                                 idToken: idToken, accessToken: token.access_token, refreshToken: token.refresh_token,
                                 expiresAt: now.addingTimeInterval(TimeInterval(token.expires_in ?? 3600)),
                                 scopes: token.scopes, savedAt: now)
    }

    public static func claims(ofJWT jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3, let data = Base64URL.decode(String(parts[1])) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
