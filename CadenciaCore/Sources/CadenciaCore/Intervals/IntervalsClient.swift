import Foundation

/// How the app authenticates against Intervals.icu.
public enum IntervalsCredential: Codable, Equatable, Sendable {
    /// Personal use: HTTP basic auth, username "API_KEY".
    case apiKey(String)
    /// OAuth bearer token issued to the registered Cadencia app.
    case oauth(accessToken: String, scopes: [String])

    var authorizationHeader: String {
        switch self {
        case .apiKey(let key):
            return "Basic " + Data("API_KEY:\(key)".utf8).base64EncodedString()
        case .oauth(let token, _):
            return "Bearer \(token)"
        }
    }
}

/// Thin, typed client for the parts of the Intervals.icu API Cadencia uses.
/// Endpoints and field names follow https://intervals.icu/api/v1/docs.
public struct IntervalsClient: Sendable {
    public static let baseURL = URL(string: "https://intervals.icu")!

    public var transport: any HTTPTransport
    public var credential: IntervalsCredential
    public var baseURL: URL
    /// "0" means "the athlete who owns the credential".
    public var athleteID: String

    public init(transport: any HTTPTransport, credential: IntervalsCredential, athleteID: String = "0", baseURL: URL = IntervalsClient.baseURL) {
        self.transport = transport
        self.credential = credential
        self.athleteID = athleteID
        self.baseURL = baseURL
    }

    // MARK: Athlete

    public func athlete() async throws -> AthleteProfile {
        let dto: AthleteDTO = try await get("/api/v1/athlete/\(athleteID)")
        return dto.profile
    }

    // MARK: Wellness

    public func wellness(oldest: Day, newest: Day) async throws -> [WellnessDay] {
        let dtos: [WellnessDTO] = try await get("/api/v1/athlete/\(athleteID)/wellness", query: ["oldest": oldest.iso, "newest": newest.iso])
        return dtos.compactMap(\.model)
    }

    /// Writes the recovery fields Cadencia owns for a day (Health-derived HRV, resting HR, sleep).
    /// Only non-nil fields are sent, so other sources keep their values.
    public func updateWellness(_ day: WellnessDay) async throws {
        var body: [String: Any] = ["id": day.day.iso]
        if let v = day.hrvMs { body["hrv"] = v }
        if let v = day.restingHR { body["restingHR"] = v }
        if let v = day.sleepSeconds { body["sleepSecs"] = v }
        if let v = day.weightKg { body["weight"] = v }
        if let v = day.soreness { body["soreness"] = v }
        if let v = day.fatigue { body["fatigue"] = v }
        let data = try JSONSerialization.data(withJSONObject: body)
        _ = try await send(.put, "/api/v1/athlete/\(athleteID)/wellness/\(day.day.iso)", body: data, contentType: "application/json")
    }

    // MARK: Activities

    public func activities(oldest: Day, newest: Day, limit: Int? = nil) async throws -> [ActivitySummary] {
        var q = ["oldest": oldest.iso, "newest": newest.iso]
        if let limit { q["limit"] = String(limit) }
        let dtos: [ActivityDTO] = try await get("/api/v1/athlete/\(athleteID)/activities", query: q)
        return dtos.compactMap(\.model)
    }

    public func powerCurve(newest: Day, type: String = "Ride", days: Int = 42) async throws -> [PowerCurvePoint] {
        // Intervals curve ids: "42d" (last N days), "s0" (season), "r.<from>.<to>" (date range). A comma separates curves.
        let oldest = newest.adding(days: -days)
        let dto: PowerCurvesDTO = try await get("/api/v1/athlete/\(athleteID)/power-curves.json",
                                                query: ["newest": newest.iso, "now": newest.iso, "type": type, "curves": "r.\(oldest.iso).\(newest.iso)"])
        return dto.points
    }

    public struct UploadResult: Codable, Equatable, Sendable {
        public var activityID: String
        public init(activityID: String) { self.activityID = activityID }
    }

    /// Uploads a completed ride as a TCX file. `externalID` lets us reconcile duplicates if the
    /// response is lost: Intervals keeps it on the activity, and a repeat upload with the same id is rejected.
    public func uploadActivity(tcx: Data, name: String, externalID: String, pairedEventID: Int? = nil) async throws -> UploadResult {
        var multipart = MultipartBody()
        multipart.addFile(name: "file", filename: "\(externalID).tcx", contentType: "application/xml", contents: tcx)
        var query = ["name": name, "external_id": externalID, "device_name": "Cadencia"]
        if let pairedEventID { query["paired_event_id"] = String(pairedEventID) }
        let response = try await send(.post, "/api/v1/athlete/\(athleteID)/activities", query: query, body: multipart.finish(), contentType: multipart.contentType)
        // Response: {"icu_athlete_id":..., "activities":[{"id":"i123", ...}]}
        struct Envelope: Decodable { struct A: Decodable { let id: String }; let activities: [A] }
        let env = try Self.decoder.decode(Envelope.self, from: response.body)
        guard let first = env.activities.first else { throw HTTPError.invalidResponse }
        return UploadResult(activityID: first.id)
    }

    /// Finds an already-uploaded activity by the external id we assigned, to reconcile uncertain uploads.
    public func activity(externalID: String, around day: Day) async throws -> ActivitySummary? {
        let list = try await activities(oldest: day.adding(days: -1), newest: day.adding(days: 1))
        return list.first { $0.externalID == externalID }
    }

    /// Everything Intervals computed for one activity, intervals included. Right after an upload
    /// `analyzed` may still be false; callers poll until it flips.
    public func activityDetail(id: String) async throws -> ActivityDetail {
        let dto: ActivityDetailDTO = try await get("/api/v1/activity/\(id)", query: ["intervals": "true"])
        return dto.model
    }

    public func updateActivityFeedback(activityID: String, rpe: Int?, feel: Int?) async throws {
        var body: [String: Any] = [:]
        if let rpe { body["icu_rpe"] = rpe }
        if let feel { body["feel"] = feel }
        guard !body.isEmpty else { return }
        let data = try JSONSerialization.data(withJSONObject: body)
        _ = try await send(.put, "/api/v1/activity/\(activityID)", body: data, contentType: "application/json")
    }

    // MARK: Calendar

    public func events(oldest: Day, newest: Day) async throws -> [IntervalsEvent] {
        try await get("/api/v1/athlete/\(athleteID)/events.json", query: ["oldest": oldest.iso, "newest": newest.iso])
    }

    /// Creates (or updates, by `uid`) a planned workout on the athlete's calendar.
    @discardableResult
    public func upsertPlannedWorkout(_ session: PlannedSession, ftp: Int) async throws -> IntervalsEvent {
        var body: [String: Any] = [
            "category": session.kind == .race ? "RACE_A" : "WORKOUT",
            "start_date_local": "\(session.day.iso)T00:00:00",
            "type": "Ride",
            "name": session.title,
            "uid": PlanMirror.uid(for: session),
            "external_id": session.id.uuidString.lowercased(),
            "indoor": true,
        ]
        if let workout = session.workout {
            body["description"] = WorkoutText.render(workout)
            body["moving_time"] = Int(workout.totalDuration)
        } else {
            body["description"] = session.note ?? "Session to be generated on the day from recovery data."
            body["moving_time"] = session.targetMinutes * 60
            if let load = session.targetLoad { body["icu_training_load"] = load }
        }
        let data = try JSONSerialization.data(withJSONObject: body)
        let response = try await send(.post, "/api/v1/athlete/\(athleteID)/events", query: ["upsertOnUid": "true"], body: data, contentType: "application/json")
        return try Self.decoder.decode(IntervalsEvent.self, from: response.body)
    }

    public func deleteEvent(id: Int) async throws {
        _ = try await send(.delete, "/api/v1/athlete/\(athleteID)/events/\(id)")
    }

    // MARK: OAuth

    /// Revokes the bearer token for this app. Only meaningful for `.oauth` credentials.
    public func disconnectApp() async throws {
        guard case .oauth = credential else { return }
        _ = try await send(.delete, "/api/v1/disconnect-app")
    }

    // MARK: Plumbing

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        return d
    }()

    func get<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        let response = try await send(.get, path, query: query)
        do {
            return try Self.decoder.decode(T.self, from: response.body)
        } catch {
            throw HTTPError.transport("Decoding \(path): \(error)")
        }
    }

    @discardableResult
    func send(_ method: HTTPRequest.Method, _ path: String, query: [String: String] = [:], body: Data? = nil, contentType: String? = nil) async throws -> HTTPResponse {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        var headers = ["Authorization": credential.authorizationHeader, "Accept": "application/json"]
        if let contentType { headers["Content-Type"] = contentType }
        let request = HTTPRequest(method: method, url: components.url!, headers: headers, body: body)
        let response: HTTPResponse
        do {
            response = try await transport.send(request)
        } catch let e as HTTPError {
            throw e
        } catch {
            throw HTTPError.transport(String(describing: error))
        }
        guard response.isSuccess else {
            if response.status == 401 || response.status == 403 { throw HTTPError.unauthorized }
            throw HTTPError.status(response.status, String(data: response.body.prefix(300), encoding: .utf8) ?? "")
        }
        return response
    }
}

// MARK: - OAuth helpers (PKCE, public client)

public struct IntervalsOAuth: Sendable {
    public static let authorizeURL = URL(string: "https://intervals.icu/oauth/authorize")!
    public static let tokenURL = URL(string: "https://intervals.icu/api/oauth/token")!
    public static let defaultScopes = ["ACTIVITY:WRITE", "WELLNESS:READ", "CALENDAR:WRITE", "SETTINGS:READ"]

    public var clientID: String
    public var redirectURI: String
    public var scopes: [String]

    public init(clientID: String, redirectURI: String, scopes: [String] = IntervalsOAuth.defaultScopes) {
        self.clientID = clientID
        self.redirectURI = redirectURI
        self.scopes = scopes
    }

    public typealias PKCE = CadenciaCore.PKCE

    public static func makePKCE(randomBytes: [UInt8]? = nil) -> PKCE { PKCE.make(randomBytes: randomBytes) }

    public func authorizationURL(pkce: PKCE, state: String) -> URL {
        var c = URLComponents(url: Self.authorizeURL, resolvingAgainstBaseURL: false)!
        c.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "scope", value: scopes.joined(separator: ",")),
            .init(name: "state", value: state),
            .init(name: "code_challenge", value: pkce.challenge),
            .init(name: "code_challenge_method", value: "S256"),
        ]
        return c.url!
    }

    public struct TokenResponse: Decodable, Equatable, Sendable {
        public struct Athlete: Decodable, Equatable, Sendable {
            public let id: String
            public let name: String?
        }
        public let access_token: String
        public let scope: String
        public let athlete: Athlete
        public var scopes: [String] { scope.split(separator: ",").map(String.init) }
    }

    /// Exchanges the code. Public client + PKCE: no client secret is ever shipped in the app.
    public func exchange(code: String, pkce: PKCE, transport: any HTTPTransport) async throws -> TokenResponse {
        let form = ["client_id": clientID, "code": code, "code_verifier": pkce.verifier, "redirect_uri": redirectURI]
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0.value)" }
            .joined(separator: "&")
        let request = HTTPRequest(method: .post, url: Self.tokenURL,
                                  headers: ["Content-Type": "application/x-www-form-urlencoded", "Accept": "application/json"],
                                  body: Data(form.utf8))
        let response = try await transport.send(request)
        guard response.isSuccess else { throw HTTPError.status(response.status, String(data: response.body, encoding: .utf8) ?? "") }
        return try JSONDecoder().decode(TokenResponse.self, from: response.body)
    }
}
