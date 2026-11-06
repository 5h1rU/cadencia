import Foundation

/// Cadencia's backend (`web/`) as plain HTTP JSON, the API its OpenAPI document at `/v1/openapi.json`
/// describes. The calls and wire types are generated into `CadenciaAPI.generated.swift`; this file holds
/// what they share: the transport, the session token, sign-in and errors.
///
/// A command answers with a `Receipt`. A view read given that receipt waits until the view includes the
/// write; what a policy does after it (the plan's verdict on a decision, a plan created from a draft)
/// arrives later, so callers read again until it is there (`CoachBackend`).
public struct CadenciaAPI: Sendable {
    public var baseURL: URL
    public var transport: any HTTPTransport
    /// The session token `exchange(handoff:)` returned, sent as `Authorization: Bearer`.
    public var sessionToken: String?

    public init(baseURL: URL, transport: any HTTPTransport, sessionToken: String? = nil) {
        self.baseURL = baseURL
        self.transport = transport
        self.sessionToken = sessionToken
    }

    /// The input of a command that takes none (`StartConsultation`, `RetirePlan`): `{}` on the wire.
    public struct EmptyObject: Codable, Equatable, Sendable {
        public init() {}
    }

    // MARK: Brands

    /// A value of one of the domain's brands (`PlanId`, `Day`, `Minutes`, `Title`, …), generated with the
    /// same pattern, length or range the backend checks. `init?(rawValue:)` and decoding refuse anything
    /// else, so a value of this type is one the domain accepts. On the wire it is its raw value.
    public protocol Branded: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible
        where RawValue: Codable & Hashable & Sendable {
        static func accepts(_ value: RawValue) -> Bool
    }

    /// A brand of text: trimmed, not blank, and at most `maxLength` UTF-16 code units (JavaScript's length).
    public protocol BoundedText: Branded where RawValue == String {
        static var maxLength: Int { get }
    }

    /// A value outside its brand: the domain would refuse it.
    public struct InvalidValue: Error, Equatable, Sendable, CustomStringConvertible {
        public let brand: String
        public let value: String

        public var description: String { "\(value.prefix(80)) is not a valid \(brand)" }
    }

    /// Whether all of `value` matches `pattern`, as JavaScript reads it: `\d` is an ASCII digit.
    static func matches(_ value: String, _ pattern: String) -> Bool {
        guard let regex = try? Regex(pattern).asciiOnlyDigits() else { return false }
        return (try? regex.wholeMatch(in: value)) != nil
    }

    // MARK: Sign-in

    /// The callback Cadencia iOS registers: the server redirects there with `?handoff=…`.
    public static let callbackScheme = "cadencia"

    /// Where the sign-in starts: the server sends the athlete to Intervals.icu, then back to the app.
    public var signInURL: URL {
        var components = URLComponents(url: baseURL.appendingPathComponent("auth/intervals/start"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "client", value: "ios")]
        return components.url!
    }

    /// The one-minute handoff token in `cadencia://auth/callback?handoff=…`, or nil for any other URL.
    public static func handoff(from callback: URL) -> String? {
        guard callback.scheme == callbackScheme, callback.host == "auth", callback.path == "/callback",
              let value = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "handoff" })?.value, !value.isEmpty else { return nil }
        return value
    }

    /// Exchanges a handoff for a session token (`POST /auth/exchange`).
    public func exchange(handoff: String) async throws -> String {
        struct Body: Encodable { let handoff: String }
        struct Answer: Decodable { let token: String }
        let request = HTTPRequest(method: .post, url: baseURL.appendingPathComponent("auth/exchange"),
                                  headers: ["Content-Type": "application/json", "Accept": "application/json"],
                                  body: try JSONEncoder().encode(Body(handoff: handoff)))
        let response = try await send(request)
        guard let answer = try? JSONDecoder().decode(Answer.self, from: response.body), !answer.token.isEmpty else {
            throw CadenciaAPIError.invalidResponse
        }
        return answer.token
    }

    /// The athlete the session belongs to (`GET /api/session`): their Intervals.icu athlete id.
    public func signedInAthlete() async throws -> String {
        struct Answer: Decodable { let athleteId: String }
        let response = try await send(HTTPRequest(method: .get, url: baseURL.appendingPathComponent("api/session"),
                                                  headers: headers(json: false)))
        guard let answer = try? JSONDecoder().decode(Answer.self, from: response.body) else { throw CadenciaAPIError.invalidResponse }
        return answer.athleteId
    }

    // MARK: Calls

    /// `POST /v1/<Command>` with `{ target, commandId, input }`.
    func command<Input: Encodable>(_ name: String, target: String, input: Input, commandId: String?) async throws -> Receipt {
        let body = try Self.encoder.encode(CommandBody(target: target, commandId: commandId, input: input))
        let response = try await send(HTTPRequest(method: .post, url: url("v1", name), headers: headers(json: true), body: body))
        do { return try JSONDecoder().decode(Receipt.self, from: response.body) } catch { throw CadenciaAPIError.invalidResponse }
    }

    /// `GET /v1/<View>/<key>`, nil when the key has no data yet. `after` waits for that write.
    func read<State: Decodable>(_ view: String, key: String, after receipt: Receipt?) async throws -> State? {
        var components = URLComponents(url: url("v1", view, key), resolvingAgainstBaseURL: false)!
        if let receipt {
            components.queryItems = [URLQueryItem(name: "stream", value: receipt.stream),
                                     URLQueryItem(name: "version", value: Self.number(receipt.version))]
        }
        let response = try await send(HTTPRequest(method: .get, url: components.url!, headers: headers(json: false)))
        do { return try JSONDecoder().decode(State?.self, from: response.body) } catch { throw CadenciaAPIError.invalidResponse }
    }

    /// The body of every command. `commandId` is left out when there is none.
    struct CommandBody<Input: Encodable>: Encodable {
        let target: String
        let commandId: String?
        let input: Input
        enum CodingKeys: String, CodingKey { case target, commandId, input }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(target, forKey: .target)
            try c.encodeIfPresent(commandId, forKey: .commandId)
            try c.encode(input, forKey: .input)
        }
    }

    /// Sorted keys, so a command's body is the same bytes every time it is retried.
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    static func number(_ value: Double) -> String {
        value.rounded() == value && abs(value) < 1e15 ? String(Int64(value)) : String(value)
    }

    /// A path under the base URL; each segment escaped on its own, so ids keep their `:`.
    func url(_ segments: String...) -> URL {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        var url = baseURL
        for segment in segments {
            url.appendPathComponent(segment.addingPercentEncoding(withAllowedCharacters: allowed) ?? segment, isDirectory: false)
        }
        return url
    }

    private func headers(json: Bool) -> [String: String] {
        var headers = ["Accept": "application/json"]
        if json { headers["Content-Type"] = "application/json" }
        if let sessionToken { headers["Authorization"] = "Bearer \(sessionToken)" }
        return headers
    }

    private func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let response: HTTPResponse
        do { response = try await transport.send(request) } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CadenciaAPIError.transport(error.localizedDescription)
        }
        guard !response.isSuccess else { return response }
        throw CadenciaAPIError(status: response.status, body: response.body)
    }
}

extension CadenciaAPI.Branded {
    /// `value` as this brand, or `InvalidValue` when the domain would refuse it.
    public init(_ value: RawValue) throws {
        guard let branded = Self(rawValue: value) else {
            throw CadenciaAPI.InvalidValue(brand: String(describing: Self.self), value: String(describing: value))
        }
        self = branded
    }

    public var description: String { String(describing: rawValue) }
}

extension CadenciaAPI.BoundedText {
    /// What someone wrote, without the whitespace around it. Throws when it is blank or longer than the brand allows.
    public init(text: String) throws {
        try self.init(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Text the AI wrote, without the whitespace around it and shortened with "…" to the brand's length.
    /// Throws only when it is blank.
    public init(fitting text: String) throws {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.utf16.count > Self.maxLength {
            var kept = "", length = 0
            for character in value {
                length += character.utf16.count
                guard length < Self.maxLength else { break } // room for the "…"
                kept.append(character)
            }
            value = kept.trimmingCharacters(in: .whitespacesAndNewlines) + "…"
        }
        try self.init(value)
    }

    /// `init(fitting:)`, or nil when there is no text.
    public static func fitting(_ text: String?) throws -> Self? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return try Self(fitting: text)
    }
}

/// Why a call to the backend failed.
public enum CadenciaAPIError: Error, Equatable, Sendable {
    /// No session, or it expired: the athlete signs in to Cadencia again.
    case signedOut
    /// The domain refused the request, with the rejection's tag (`PlanNotActive`, `NotYours`, …) and its fields.
    case rejected(tag: String, status: Int, detail: String)
    /// The request did not match the API (400): a client bug, not the athlete's.
    case invalidRequest(String)
    case server(status: Int, body: String)
    case transport(String)
    case invalidResponse

    /// The rejection's tag, if the domain refused.
    public var rejection: String? {
        if case .rejected(let tag, _, _) = self { return tag }
        return nil
    }

    init(status: Int, body: Data) {
        let text = String(decoding: body.prefix(2000), as: UTF8.self)
        if status == 401 { self = .signedOut; return }
        if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any], let tag = json["_tag"] as? String {
            self = tag == "Unauthorized" ? .signedOut : .rejected(tag: tag, status: status, detail: text)
            return
        }
        self = status == 400 ? .invalidRequest(text) : .server(status: status, body: text)
    }
}

extension CadenciaAPIError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .signedOut: return "Sign in to Cadencia again."
        case .rejected(let tag, _, _): return "Cadencia refused the change (\(tag))."
        case .invalidRequest: return "Cadencia could not read the request."
        case .server(let status, _): return "Cadencia is unavailable (HTTP \(status))."
        case .transport(let message): return message
        case .invalidResponse: return "Invalid response from Cadencia."
        }
    }
}
