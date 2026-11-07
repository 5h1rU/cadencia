import Foundation

/// The athlete's Intervals.icu OAuth access token for Cadencia's app, handed over by Cadencia's server at
/// sign-in (`CadenciaAPI.exchange`) and sent as `Authorization: Bearer`. It is long-lived; a 401 or 403 means
/// the athlete revoked it or the app lost access, and signing in again replaces it.
public struct IntervalsCredential: Codable, Equatable, Sendable {
    public var accessToken: String

    public init(accessToken: String) {
        self.accessToken = accessToken
    }

    var authorizationHeader: String { "Bearer \(accessToken)" }
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
        var update = WellnessUpdate(health: day)
        update.soreness = day.soreness
        update.fatigue = day.fatigue
        try await updateWellness(update)
    }

    /// `PUT /wellness/{date}`: only the fields provided change. With `localDate` equal to the record's day,
    /// Intervals also updates the athlete's current weight / resting HR in settings.
    public func updateWellness(_ update: WellnessUpdate, localDate: Day? = nil) async throws {
        let data = try JSONSerialization.data(withJSONObject: update.body, options: [.sortedKeys])
        var query: [String: String] = [:]
        if let localDate { query["localDate"] = localDate.iso }
        _ = try await send(.put, "/api/v1/athlete/\(athleteID)/wellness/\(update.day.iso)", query: query, body: data, contentType: "application/json")
    }

    /// `PUT /wellness-bulk`: several days in one request, each keyed by its `id` (the day).
    public func updateWellness(_ updates: [WellnessUpdate]) async throws {
        guard !updates.isEmpty else { return }
        if updates.count == 1 { return try await updateWellness(updates[0]) }
        let data = try JSONSerialization.data(withJSONObject: updates.map(\.body), options: [.sortedKeys])
        _ = try await send(.put, "/api/v1/athlete/\(athleteID)/wellness-bulk", body: data, contentType: "application/json")
    }

    // MARK: Settings

    /// `PUT /sport-settings/Ride`: the cycling FTP (and indoor FTP, when the athlete uses one).
    public func updateRideFTP(_ ftp: Int, athlete: AthleteProfile?) async throws {
        let data = try JSONSerialization.data(withJSONObject: IntervalsAthleteFields.rideFTPBody(ftp: ftp, athlete: athlete), options: [.sortedKeys])
        _ = try await send(.put, "/api/v1/athlete/\(athleteID)/sport-settings/Ride", body: data, contentType: "application/json")
    }

    /// `PUT /athlete/{id}` with only the given fields: height (sent in metres), `measurement_preference`
    /// and the default weekly `training_availability`.
    public func updateAthlete(heightCm: Double? = nil, measurementPreference: String? = nil,
                              trainingAvailability: [IntervalsAvailabilityDay]? = nil) async throws {
        var body: [String: Any] = [:]
        if let heightCm { body["height"] = IntervalsAthleteFields.meters(fromCm: heightCm) }
        if let measurementPreference { body["measurement_preference"] = measurementPreference }
        if let trainingAvailability { body["training_availability"] = trainingAvailability.map(\.body) }
        guard !body.isEmpty else { return }
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        _ = try await send(.put, "/api/v1/athlete/\(athleteID)", body: data, contentType: "application/json")
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

    /// Dedicated, read-only history for the rider profile. Does not expand daily-coaching inputs
    /// or reuse the daily 42-day power curve as if it covered six months.
    public func cyclistProfileBrief(newest: Day, locale: String) async throws -> CyclistProfile.Brief {
        let athlete = try await athlete()
        let activities = try await activities(oldest: newest.adding(days: -(CyclistProfile.historyDays - 1)), newest: newest)
        var curve: [PowerCurvePoint] = []
        var unavailable = false
        do {
            curve = try await powerCurve(newest: newest, days: CyclistProfile.historyDays - 1)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as HTTPError where error.isAuthFailure {
            throw error
        } catch {
            // Sparse accounts can lack a power curve. Keep the riding history and explicitly tell
            // the coach that the curve could not be read; never substitute the shorter cached curve.
            unavailable = true
        }
        try Task.checkCancellation()
        return CyclistProfile.Brief(locale: locale, newest: newest, athlete: athlete, activities: activities,
                                    powerCurve: curve, powerCurveUnavailable: unavailable)
    }

    public struct UploadResult: Codable, Equatable, Sendable {
        public var activityID: String
        public init(activityID: String) { self.activityID = activityID }
    }

    /// Reconcile before every attempt, including rides whose last attempt used TCX. A failed
    /// lookup stops the upload; changing formats must never create a second copy of a ride.
    public func uploadActivity(_ ride: RideRecording) async throws -> UploadResult {
        if let existing = try await activity(externalID: ride.externalID, around: Day(ride.startedAt)) {
            return UploadResult(activityID: existing.id)
        }
        return try await uploadActivity(fit: FITActivityEncoder.encode(ride), name: ride.workout.name,
                                        externalID: ride.externalID, pairedEventID: ride.intervalsEventID)
    }

    /// Uploads a completed ride as a FIT activity file. `externalID` lets us reconcile duplicates if the
    /// response is lost: Intervals keeps it on the activity, and a repeat upload with the same id is rejected.
    public func uploadActivity(fit: Data, name: String, externalID: String, pairedEventID: Int? = nil) async throws -> UploadResult {
        var multipart = MultipartBody()
        multipart.addFile(name: "file", filename: "\(externalID).fit", contentType: "application/octet-stream", contents: fit)
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

    /// Official recorded-GPS export. Strava-sourced activities and rides without GPS may lack it.
    public func activityGPX(id: String) async throws -> Data {
        let response = try await send(.get, "/api/v1/activity/\(id)/gpx-file", query: ["power": "false", "hr": "false"])
        guard response.body.count <= GPXImporter.maximumBytes else { throw GPXImporter.ImportError.tooLarge }
        return response.body
    }

    public func updateActivityFeedback(activityID: String, rpe: Int?, feel: Int?) async throws {
        var body: [String: Any] = [:]
        if let rpe { body["icu_rpe"] = rpe }
        if let feel { body["feel"] = feel }
        guard !body.isEmpty else { return }
        let data = try JSONSerialization.data(withJSONObject: body)
        _ = try await send(.put, "/api/v1/activity/\(activityID)", body: data, contentType: "application/json")
    }

    /// Notes are messages, separate from the activity description. Read all pages so a retry can
    /// reconcile an accepted POST whose response was lost, even on an activity with many comments.
    public func activityNotes(activityID: String) async throws -> [IntervalsActivityNote] {
        var notes: [IntervalsActivityNote] = []
        var sinceID: Int64 = 0
        while true {
            let page: [IntervalsActivityNote] = try await get("/api/v1/activity/\(activityID)/messages",
                query: ["sinceId": String(sinceID), "limit": "100"])
            notes.append(contentsOf: page)
            guard page.count == 100, let nextID = page.map(\.id).max(), nextID > sinceID else { break }
            sinceID = nextID
        }
        return notes
    }

    /// Reuse the activity's saved debrief instead of appending it on each refresh/retry.
    public func saveDebriefNote(activityID: String, report: RideDebrief.Report) async throws -> IntervalsActivityNote {
        let content = report.noteContent
        if let existing = try await activityNotes(activityID: activityID).first(where: { $0.isCoachDebrief && $0.content == content }) { return existing }
        let body = try JSONEncoder().encode(["content": content])
        let response = try await send(.post, "/api/v1/activity/\(activityID)/messages", body: body, contentType: "application/json")
        struct Result: Decodable { let id: Int64 }
        let result = try Self.decoder.decode(Result.self, from: response.body)
        return IntervalsActivityNote(id: result.id, content: content)
    }

    // MARK: Calendar

    public func events(oldest: Day, newest: Day) async throws -> [IntervalsEvent] {
        try await get("/api/v1/athlete/\(athleteID)/events.json", query: ["oldest": oldest.iso, "newest": newest.iso])
    }

    /// Updates by the server's event id. A failed/uncertain create must be reconciled by external id
    /// before retrying: Intervals may replace the UID, so upsertOnUid alone is not idempotent.
    @discardableResult
    public func upsertPlannedWorkout(_ session: PlannedSession, ftp: Int, existingEventID: Int? = nil) async throws -> IntervalsEvent {
        var body: [String: Any] = [
            "category": session.kind == .race ? "RACE_A" : "WORKOUT",
            "start_date_local": "\(session.day.iso)T00:00:00",
            "type": "Ride",
            "name": session.title,
            "external_id": PlanMirror.externalID(for: session),
            "indoor": session.location != .outdoor,
            "icu_ftp": PlanMirror.eventFTP(for: session, ftp: ftp),
            "tags": PlanMirror.tags(for: session.kind),
        ]
        let eventID = existingEventID ?? session.intervalsEventID
        if eventID == nil { body["uid"] = PlanMirror.uid(for: session) }
        if let workout = session.workout {
            body["description"] = WorkoutText.render(workout, ftp: session.location == .outdoor ? ftp : nil)
            body["moving_time"] = Int(workout.totalDuration)
        } else {
            body["description"] = session.note ?? "Session to be generated on the day from recovery data."
            body["moving_time"] = session.targetMinutes * 60
            body["icu_training_load"] = session.targetLoad.map { $0 as Any } ?? NSNull()
        }
        let data = try JSONSerialization.data(withJSONObject: body)
        let response: HTTPResponse
        if let eventID {
            response = try await send(.put, "/api/v1/athlete/\(athleteID)/events/\(eventID)", body: data, contentType: "application/json")
        } else {
            response = try await send(.post, "/api/v1/athlete/\(athleteID)/events", query: ["upsertOnUid": "true"], body: data, contentType: "application/json")
        }
        return try Self.decoder.decode(IntervalsEvent.self, from: response.body)
    }

    public func deleteEvent(id: Int) async throws {
        _ = try await send(.delete, "/api/v1/athlete/\(athleteID)/events/\(id)")
    }

    /// Official calendar export endpoint. Match by server id, never by name or date alone.
    public func plannedWorkoutFIT(eventID: Int, day: Day) async throws -> Data {
        struct Export: Decodable { let id: Int; let workout_file_base64: String? }
        let exports: [Export] = try await get("/api/v1/athlete/\(athleteID)/events", query: [
            "oldest": day.iso, "newest": day.iso, "ext": "fit", "resolve": "true"
        ])
        guard let encoded = exports.first(where: { $0.id == eventID })?.workout_file_base64,
              let data = Data(base64Encoded: encoded), data.count >= 14,
              String(data: data[8..<12], encoding: .ascii) == ".FIT" else { throw HTTPError.invalidResponse }
        return data
    }

    /// Delete only the explicitly selected server ids. Never send external ids here: legacy copies
    /// share them with the entry being retained.
    public func deleteEvents(ids: [Int]) async throws -> Int {
        let uniqueIDs = Set(ids).sorted()
        guard !uniqueIDs.isEmpty else { return 0 }
        let body = try JSONSerialization.data(withJSONObject: uniqueIDs.map { ["id": $0] })
        let response = try await send(.put, "/api/v1/athlete/\(athleteID)/events/bulk-delete", body: body, contentType: "application/json")
        struct Result: Decodable { let eventsDeleted: Int }
        return try Self.decoder.decode(Result.self, from: response.body).eventsDeleted
    }

    /// `PUT /events/bulk-delete`. A retired entry is named by its external id (Intervals then deletes every
    /// copy the app created, all of which belong to it) and, when known, by its server id: deletion by
    /// external id only covers events created by Cadencia's OAuth app, not ones earlier builds created with an API key.
    /// Missing events are ignored.
    @discardableResult
    public func deleteEvents(_ deletions: [CalendarSync.Deletion]) async throws -> Int {
        var items: [[String: Any]] = []
        for externalID in Set(deletions.compactMap(\.externalID)).sorted() { items.append(["external_id": externalID]) }
        for id in Set(deletions.compactMap(\.eventID)).sorted() { items.append(["id": id]) }
        guard !items.isEmpty else { return 0 }
        let body = try JSONSerialization.data(withJSONObject: items, options: [.sortedKeys])
        let response = try await send(.put, "/api/v1/athlete/\(athleteID)/events/bulk-delete", body: body, contentType: "application/json")
        struct Result: Decodable { let eventsDeleted: Int? }
        return (try? Self.decoder.decode(Result.self, from: response.body).eventsDeleted) ?? 0
    }

    /// `POST /events/bulk?upsert=true`: an existing event of Cadencia's OAuth app with the same external id is
    /// updated instead of duplicated. Callers read the calendar first, which also covers events created otherwise.
    public func createCalendarEntries(_ entries: [CalendarEntry]) async throws -> [IntervalsEvent] {
        guard !entries.isEmpty else { return [] }
        let body = try JSONSerialization.data(withJSONObject: entries.map(\.body), options: [.sortedKeys])
        let response = try await send(.post, "/api/v1/athlete/\(athleteID)/events/bulk", query: ["upsert": "true"],
                                      body: body, contentType: "application/json")
        // The ids are a convenience; the next pass finds the events by external id if this does not decode.
        return (try? Self.decoder.decode([IntervalsEvent].self, from: response.body)) ?? []
    }

    public func updateCalendarEntry(_ entry: CalendarEntry, eventID: Int) async throws -> IntervalsEvent {
        var fields = entry.body
        fields["uid"] = nil
        let body = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        let response = try await send(.put, "/api/v1/athlete/\(athleteID)/events/\(eventID)", body: body, contentType: "application/json")
        return try Self.decoder.decode(IntervalsEvent.self, from: response.body)
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
