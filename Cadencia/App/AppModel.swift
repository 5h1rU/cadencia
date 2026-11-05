import Foundation
import Observation
import CadenciaCore

#if DEBUG
private struct SyncAuditTransport: HTTPTransport {
    let directory: URL

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let response = try await URLSession.shared.send(request)
        if request.method == .get, response.isSuccess {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try response.body.write(to: directory.appendingPathComponent(request.url.lastPathComponent + ".json"), options: .atomic)
        }
        return response
    }
}
#endif

/// Single owner of app state. Views read it through the environment; all mutation goes through methods
/// here so persistence, Intervals sync and the coaching engines stay in one place.
@MainActor
@Observable
final class AppModel {
    private(set) var state: AppState
    private(set) var credential: IntervalsCredential?
    private(set) var isSyncing = false
    private(set) var syncError: String?
    private(set) var coachBusy = false
    private(set) var cyclistProfileBusy = false
    private(set) var cyclistProfileError: String?
    private(set) var consultationBusy = false
    private(set) var consultationError: String?
    private var consultationRequestID: UUID?
    private var syncingProfileWeight = false
    private(set) var isUploading = false

    /// Sign in with ChatGPT. Tokens live in the Keychain; the issued client id and the per-device host id
    /// survive sign-out so the next sign-in reuses the registration, as OpenAI requires.
    private(set) var chatGPT: ChatGPTCredential?
    private(set) var coachIssue: CoachIssue?
    /// True while the language model is deciding today's session.
    private(set) var coachThinking = false
    /// Why today shows the rule-based plan although an AI coach is configured (transport or safety failure).
    private(set) var coachNotice: String?
    var showChatGPTWelcome = false
    /// Where each ride's post-ride debrief stands. No entry: not started, or done (`ride.debrief` is set).
    private(set) var debriefStatus: [UUID: DebriefStatus] = [:]
    private(set) var debriefNoteErrors: [UUID: String] = [:]
    private var syncingDebriefNotes: Set<UUID> = []
    private(set) var rideRouteStatus: [UUID: RideRouteStatus] = [:]
    enum RideRouteStatus: Equatable { case loading, unavailable, failed(String) }

    enum DebriefStatus: Equatable {
        /// Intervals is still processing the upload.
        case waitingForIntervals
        /// The coach has the numbers and is writing.
        case reading
        case failed(String)
    }

    enum CoachIssue: Equatable {
        case usageLimit, notEligible, signInAgain
    }

    let bluetooth: BluetoothManager
    let health: HealthKitService
    private let store: JSONStore
    private let keychain: KeychainStore
    private let transport: any HTTPTransport
    private let coachOverride: LLMCoach?
    private var rideCache: [UUID: RideRecording] = [:]
    private var isMirroring = false
    private var calendarWaiters: [CheckedContinuation<Void, Never>] = []

    private static let stateFile = "state.json"
    private static let credentialAccount = "intervals.credential"
    private static let llmKeyAccount = "llm.apiKey"
    private static let chatGPTAccount = "chatgpt.credential"
    private static let chatGPTClientIDAccount = "chatgpt.clientID"
    private static let chatGPTHostIDAccount = "chatgpt.hostID"

    init(state: AppState, credential: IntervalsCredential?, store: JSONStore, keychain: KeychainStore,
         transport: any HTTPTransport, bluetooth: BluetoothManager = BluetoothManager(), health: HealthKitService = HealthKitService(),
         coachOverride: LLMCoach? = nil) {
        self.state = state
        self.credential = credential
        self.store = store
        self.keychain = keychain
        self.transport = transport
        self.coachOverride = coachOverride
        self.bluetooth = bluetooth
        self.health = health
        self.chatGPT = keychain.readCodable(ChatGPTCredential.self, account: Self.chatGPTAccount)
    }

    static func live() -> AppModel {
        let store = JSONStore.live()
        let keychain = KeychainStore.live
        let state = store.load(AppState.self, at: stateFile) ?? AppState()
        let credential = keychain.readCodable(IntervalsCredential.self, account: credentialAccount)
        return AppModel(state: state, credential: credential, store: store, keychain: keychain, transport: URLSession.shared)
    }

    // MARK: Derived

    var today: Day { Day(Date()) }
    var isSignedIn: Bool { credential != nil }
    var athleteID: String { state.athlete?.id ?? "0" }
    var workingFTP: Int? { state.workingFTP }
    var readiness: Readiness? { state.today?.day == today ? state.today?.readiness : nil }
    var todayWorkout: Workout? { state.today?.day == today ? state.today?.workout : nil }
    var plannedToday: PlannedSession? { state.session(on: today) }
    var isTodayWorkoutCompleted: Bool { state.isWorkoutCompleted(on: today) || completedRideToday != nil }

    func completedRide(for session: PlannedSession) -> AppState.RideIndexEntry? {
        state.rideIndex.sorted { $0.startedAt > $1.startedAt }.first {
            guard let ride = ride(id: $0.id), ride.athleteID == athleteID else { return false }
            return ride.completes(session)
        }
    }

    var completedRideToday: AppState.RideIndexEntry? {
        if state.today?.day == today, let id = state.today?.completedRideID,
           let entry = state.rideIndex.first(where: { $0.id == id }) { return entry }
        if let session = plannedToday, let entry = completedRide(for: session) { return entry }
        return state.rideIndex.sorted { $0.startedAt > $1.startedAt }.first {
            guard Day($0.startedAt) == today, let ride = ride(id: $0.id), ride.athleteID == athleteID else { return false }
            return ride.endedAt != nil && ride.workout.id == todayWorkout?.id
        }
    }
    var todayWellness: WellnessDay? { state.wellness(on: today) }
    var latestWellness: WellnessDay? { state.wellness.last }

    /// The selected day's Intervals values, including planned load. Never substitute yesterday in the UI.
    var latestLoad: WellnessDay? {
        state.wellness.last { $0.day <= today && $0.ctl != nil && $0.atl != nil }
    }

    /// Actual load through yesterday, kept separate from today's planned-inclusive projection.
    var loadBeforeToday: WellnessDay? {
        state.wellness.last { $0.day < today && $0.ctl != nil && $0.atl != nil }
    }

    var upcomingEvent: TrainingEvent? {
        if let event = state.plan?.event, event.day >= today { return event }
        // Intervals remains the source of event context when there is no local Cadencia plan.
        return state.calendarEvents?.sorted {
            if $0.day == $1.day { return $0.id > $1.id }
            return ($0.day ?? today) < ($1.day ?? today)
        }.compactMap(\.trainingEvent).first { $0.day >= today }
    }

    var thisWeekEvent: TrainingEvent? {
        guard let e = upcomingEvent, e.day <= today.adding(days: 7) else { return nil }
        return e
    }

    var ftpProposal: Int? {
        guard let current = workingFTP, let estimate = state.ftpEstimate else { return nil }
        let since = today.adding(days: -estimate.windowDays)
        let activityEFTP = state.activities.filter { $0.isCycling && $0.day >= since && $0.day <= today }.compactMap(\.estimatedFTP).max()
        let runningEFTP = state.wellness.last { $0.day <= today && $0.estimatedFTP != nil }?.estimatedFTP.map { Int($0.rounded()) }
        let recentEFTP = [activityEFTP, runningEFTP].compactMap { $0 }.max()
        guard let proposal = FTPEstimator().proposal(current: current, estimate: estimate, recentEFTP: recentEFTP) else { return nil }
        return proposal == state.dismissedFTPProposal ? nil : proposal
    }

    /// The coach's note at the top of Today, in the AI coach's own words. Nil until it has decided the day.
    var coachNote: CoachNote? {
        guard let t = state.today, t.day == today, let ai = t.ai, !ai.note.isEmpty else { return nil }
        return ai.note
    }

    var pendingUploads: [UploadEntry] { state.ledger.pending(for: athleteID) }

    var hasLLMKey: Bool { keychain.readString(Self.llmKeyAccount)?.isEmpty == false }

    var client: IntervalsClient? {
        credential.map { IntervalsClient(transport: transport, credential: $0, athleteID: athleteID) }
    }

    /// Which AI answers: the athlete's ChatGPT plan, or their own API key. There is no on-device
    /// fallback; without one of these the coach, and so Today, cannot work.
    enum CoachSource: Equatable { case chatGPTPlan, apiKey }

    var coachSource: CoachSource? {
        // While a plan problem is showing (limit reached, sign-in dead) the API key is tried if there is one;
        // dismissing the banner tries the plan again.
        if chatGPT?.planUsageEnabled == true, coachIssue == nil { return .chatGPTPlan }
        if state.settings.llmEnabled, hasLLMKey { return .apiKey }
        return nil
    }

    /// Whether any AI coach is connected. Today and the coach chat need one.
    var aiCoachAvailable: Bool { coachOverride != nil || coachSource != nil }

    /// Resolves the coach for one request, refreshing the ChatGPT token first when it is about to expire.
    /// Nil when the ChatGPT sign-in is dead (`coachIssue` is set) and no API key exists.
    private func coachEngine() async -> LLMCoach? {
        if let coachOverride { return coachOverride }
        switch coachSource {
        case .chatGPTPlan:
            guard let credential = await freshChatGPTCredential() else { return nil }
            return LLMCoach(transport: transport, backend: .chatGPTPlan(accessToken: credential.accessToken), model: state.settings.llmModel)
        case .apiKey:
            let key = keychain.readString(Self.llmKeyAccount) ?? ""
            return LLMCoach(transport: transport, endpoint: state.settings.llmEndpoint, apiKey: key, model: state.settings.llmModel)
        case nil:
            return nil
        }
    }

    /// The voice for one ride, on the same coach that decided the day. Nil without a coach, or when the
    /// athlete turned both voice and captions off.
    func rideCommentator() async -> RideCommentator? {
        let settings = state.settings
        guard settings.rideVoice || settings.rideCaptions, let coach = await coachEngine() else { return nil }
        return RideCommentator(coach: coach, locale: coachLocale, openAISpeech: openAISpeech,
                               voiceEnabled: settings.rideVoice, captionsEnabled: settings.rideCaptions)
    }

    /// OpenAI text-to-speech for the ride coach. Needs an API key: the ChatGPT plan sign-in only covers
    /// `/v1/responses`, so without a key the phone's own voice speaks.
    var openAISpeech: RideCommentator.OpenAISpeech? {
        guard let key = keychain.readString(Self.llmKeyAccount), !key.isEmpty,
              CoachVoice.speechURL(nextTo: state.settings.llmEndpoint) != nil else { return nil }
        return RideCommentator.OpenAISpeech(transport: transport, endpoint: state.settings.llmEndpoint, apiKey: key, voice: state.settings.coachVoice)
    }

    // MARK: Lifecycle

    func start() async {
        guard isSignedIn else { return }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--cadencia-audit-sync"), let credential {
            let capture = SyncAuditTransport(directory: store.url("sync-audit"))
            let audit = IntervalsClient(transport: capture, credential: credential, athleteID: athleteID)
            do {
                _ = try await audit.events(oldest: today, newest: today.adding(days: 365))
                _ = try await audit.wellness(oldest: today.adding(days: -90), newest: today)
                _ = try await audit.athlete()
            } catch { try? store.save(error.localizedDescription, at: "sync-audit/error.json") }
            return
        }
        #endif
        await upgradeSavedRouteTerrain()
        await refresh()
    }

    /// Adds climb details to old saved routes without changing the athlete's confirmed course metrics.
    private func upgradeSavedRouteTerrain() async {
        guard let route = state.plan?.event?.course?.route,
              route.climbAnalysisVersion != ClimbAnalyzer.version || route.profileSegments == nil else { return }
        guard let upgraded = try? await Task.detached(priority: .userInitiated, operation: {
            try route.upgradingClimbAnalysis()
        }).value, !Task.isCancelled, state.plan?.event?.course?.route?.id == route.id,
              state.plan?.event?.course?.route?.climbAnalysisVersion != ClimbAnalyzer.version || state.plan?.event?.course?.route?.profileSegments == nil else { return }
        mutate { $0.plan?.event?.course?.route = upgraded }
    }

    private func persist() {
        do { try store.save(state, at: Self.stateFile) } catch { syncError = error.localizedDescription }
    }

    private func mutate(_ body: (inout AppState) -> Void) {
        body(&state)
        persist()
    }

    // MARK: Account

    func signIn(apiKey: String) async throws {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let probe = IntervalsClient(transport: transport, credential: .apiKey(trimmed))
        let athlete = try await probe.athlete()
        setCredential(.apiKey(trimmed), athlete: athlete)
        await refresh()
    }

    func signInWithOAuth() async throws {
        let token = try await OAuthSignIn().signIn(transport: transport)
        let credential = IntervalsCredential.oauth(accessToken: token.access_token, scopes: token.scopes)
        let athlete = try await IntervalsClient(transport: transport, credential: credential).athlete()
        setCredential(credential, athlete: athlete)
        await refresh()
    }

    private func setCredential(_ credential: IntervalsCredential, athlete: AthleteProfile) {
        cyclistProfileError = nil
        self.credential = credential
        keychain.writeCodable(credential, account: Self.credentialAccount)
        mutate {
            if $0.athlete?.id != athlete.id {
                // A different athlete: their data must not mix with the previous account's.
                let ledger = $0.ledger
                let settings = $0.settings
                $0 = AppState()
                $0.ledger = ledger
                $0.settings = settings
            }
            $0.athlete = athlete
            $0.ledger.reconnect(athleteID: athlete.id)
        }
        syncError = nil
    }

    /// Signs out. Rides that have not reached Intervals stay on disk, parked under this athlete's id,
    /// and resume when the same athlete signs back in.
    func signOut() async {
        if let client, case .oauth = client.credential { try? await client.disconnectApp() }
        credential = nil
        cyclistProfileError = nil
        keychain.delete(Self.credentialAccount)
        bluetooth.disconnectAll()
        mutate {
            $0.wellness = []
            $0.activities = []
            $0.calendarEvents = nil
            $0.powerCurve = []
            $0.today = nil
            $0.lastSyncAt = nil
        }
    }

    // MARK: ChatGPT

    /// Stable `ext_agent_host_id` for this install; created once and kept across sign-outs.
    private var chatGPTHostID: String {
        if let id = keychain.readString(Self.chatGPTHostIDAccount) { return id }
        let id = "urn:uuid:" + UUID().uuidString.lowercased()
        keychain.write(id, account: Self.chatGPTHostIDAccount)
        return id
    }

    /// Signs in (or re-consents when `requestPlanUsage` is set) and stores the credential.
    func signInWithChatGPT(requestPlanUsage: Bool = false) async throws {
        let issuedClientID = chatGPT?.clientID ?? keychain.readString(Self.chatGPTClientIDAccount)
        let credential = try await ChatGPTSignIn().signIn(clientID: issuedClientID, hostID: chatGPTHostID,
                                                          idTokenHint: chatGPT?.idToken, loginHint: chatGPT?.email,
                                                          forceConsent: requestPlanUsage, transport: transport)
        setChatGPT(credential)
        coachIssue = nil
        if credential.planUsageEnabled, state.chatGPTWelcomeShownAt == nil {
            showChatGPTWelcome = true
            mutate { $0.chatGPTWelcomeShownAt = Date() }
        }
        Task { await askCoachForToday() }
    }

    /// Revokes the tokens at OpenAI and forgets them. Registration ids stay so re-signing in is a reauthorization.
    func signOutChatGPT() async {
        if let chatGPT { try? await ChatGPTAuth().revoke(chatGPT, transport: transport) }
        chatGPT = nil
        keychain.delete(Self.chatGPTAccount)
        if coachIssue != nil { coachIssue = nil }
    }

    private func setChatGPT(_ credential: ChatGPTCredential) {
        chatGPT = credential
        keychain.writeCodable(credential, account: Self.chatGPTAccount)
        keychain.write(credential.clientID, account: Self.chatGPTClientIDAccount)
    }

    private var chatGPTRefresh: Task<ChatGPTCredential?, Never>?

    /// Returns a credential whose access token is valid for at least a minute, refreshing once even when
    /// several callers ask at the same time. Returns nil (and flags `signInAgain`) when the refresh token is dead.
    private func freshChatGPTCredential() async -> ChatGPTCredential? {
        guard let current = chatGPT else { return nil }
        guard current.needsRefresh() else { return current }
        if let inFlight = chatGPTRefresh { return await inFlight.value }
        let task = Task<ChatGPTCredential?, Never> { [transport] in
            do {
                let next = try await ChatGPTAuth().refresh(current, transport: transport)
                self.setChatGPT(next)
                return next
            } catch ChatGPTAuth.Failure.refreshTokenUnusable {
                self.coachIssue = .signInAgain
                return nil
            } catch {
                // Network blip: keep the stored tokens; use the old one while it is still valid.
                return Date() < current.expiresAt ? current : nil
            }
        }
        chatGPTRefresh = task
        defer { chatGPTRefresh = nil }
        return await task.value
    }

    /// Models the athlete's plan (or key) can use, for the Settings picker. Chooses the first listed
    /// one when the stored model id is not available on this account, so nothing stays hardcoded.
    func listCoachModels() async throws -> [LLMCoach.Model] {
        guard let engine = await coachEngine() else { return [] }
        let models = try await engine.listModels()
        if !models.isEmpty, !models.contains(where: { $0.id == state.settings.llmModel }), let first = models.first {
            setCoachModel(first.id)
        }
        return models
    }

    /// Switches the model and has it decide today again.
    func setCoachModel(_ id: String) {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != state.settings.llmModel else { return }
        mutate { $0.settings.llmModel = trimmed }
        Task { await askCoachForToday(force: true) }
    }

    /// Clears a plan problem and lets the plan coach try today again.
    func dismissCoachIssue() {
        coachIssue = nil
        Task { await askCoachForToday() }
    }

    // MARK: Sync

    func refresh() async {
        guard let client, !isSyncing else { return }
        let account = athleteID
        isSyncing = true
        defer { isSyncing = false }

        // Each fetch is independent: a failing request (for example a malformed power-curve query)
        // must not discard the athlete, wellness, and activities that did arrive. The first failure
        // is surfaced; an auth failure wins over everything else because the user has to act on it.
        var failures: [(String, Error)] = []

        do {
            let athlete = try await client.athlete()
            guard isSignedIn, athleteID == account else { return }
            mutate { $0.athlete = athlete }
        } catch { failures.append(("athlete", error)) }

        if (failures.first?.1 as? HTTPError)?.isAuthFailure == true {
            syncError = String(localized: "Intervals rejected the credential. Reconnect in Settings.")
        } else {
            do {
                let wellness = try await client.wellness(oldest: today.adding(days: -90), newest: today)
                guard isSignedIn, athleteID == account else { return }
                mutate { $0.mergeWellness(wellness) }
            } catch { failures.append(("wellness", error)) }

            do {
                let activities = try await client.activities(oldest: today.adding(days: -42), newest: today)
                guard isSignedIn, athleteID == account else { return }
                mutate { $0.activities = activities }
                try importOutdoorRides(activities)
            } catch { failures.append(("activities", error)) }

            do {
                let curve = try await client.powerCurve(newest: today)
                guard isSignedIn, athleteID == account else { return }
                mutate { $0.powerCurve = curve }
            } catch { failures.append(("power curve", error)) }

            do {
                let events = try await client.events(oldest: today, newest: today.adding(days: 42))
                guard isSignedIn, athleteID == account else { return }
                mutate { $0.calendarEvents = events }
            } catch { failures.append(("calendar", error)) }

            if failures.count < 5 {
                mutate { $0.lastSyncAt = Date() }
            }
            syncError = failures.first.map { "Intervals \($0.0): \($0.1.localizedDescription)" }
        }

        await readHealth()
        await syncProfileWeight()
        await retirePlanEvents()
        recomputeFTPEstimate()
        await askCoachForToday()
        await runUploads()
        await pushWeekToIntervals()
        debriefRecentRides()
    }

    func readHealth() async {
        guard state.settings.readHealth, HealthKitService.isAvailable else { return }
        do {
            if !state.healthAuthorized {
                try await health.requestAuthorization()
                mutate { $0.healthAuthorized = true }
            }
            let days = try await health.readWellness(days: 90)
            mutate {
                $0.mergeWellness(days)
                $0.lastHealthReadAt = Date()
            }
            if let measurements = try? await health.readBodyMeasurements() {
                mutate {
                    var current = $0.cyclistMeasurements ?? CyclistMeasurements()
                    current.merge(measurements)
                    $0.cyclistMeasurements = current
                }
            }
            if state.settings.pushWellnessToIntervals, let client, let todayHealth = days.first(where: { $0.day == today }) {
                try? await client.updateWellness(todayHealth)
            }
        } catch {
            syncError = error.localizedDescription
        }
    }

    func enableHealth() async {
        mutate { $0.settings.readHealth = true }
        await readHealth()
        await askCoachForToday()
    }

    // MARK: Today

    /// Today's wellness against the athlete's own range: measurements for the model and for the Recovery row.
    private func measuredToday(in snapshot: AppState? = nil) -> Readiness {
        let state = snapshot ?? self.state
        let day = today
        var todayWellness = state.wellness(on: day) ?? WellnessDay(day: day)
        // Today's projected load is displayed separately; it is not fatigue already accumulated.
        todayWellness.ctl = loadBeforeToday?.ctl
        todayWellness.atl = loadBeforeToday?.atl
        return ReadinessEngine().evaluate(today: todayWellness, history: state.wellness, feedback: state.feedback(for: day))
    }

    /// Everything the AI coach is shown. Built fresh each time so the fingerprint tracks the real inputs.
    private func coachBrief(applying intent: CoachIntent? = nil) -> CoachBrief {
        var state = self.state
        if let intent { state.applyCoachIntent(intent, on: today) }
        let available = state.plan?.availability.minutesByWeekday[today.weekday()]
        let requestedLimit = state.workoutRequests?[today.iso]?.maxMinutes ?? intent?.constraints.first { $0.day == today }?.maxMinutes
        let feedback = Dictionary(uniqueKeysWithValues: state.feedbackByDay.values.map { ($0.day, $0) })
        let event = state.plan?.event.flatMap { $0.day >= today ? $0 : nil } ?? upcomingEvent
        var brief = CoachBrief(today: today, locale: coachLocale,
                          athlete: .init(ftp: workingFTP ?? 200, weightKg: state.weightKg,
                                         maxHR: state.athlete?.maxHR, lthr: state.athlete?.lthr),
                          ftpEstimate: state.ftpEstimate, powerCurve: state.powerCurve,
                          wellness: state.wellness, feedback: feedback, activities: state.activities,
                          plan: state.plan, upcomingEvent: event,
                          availableMinutes: [available, requestedLimit].compactMap { $0 }.min(), recentCoachNotes: state.appliedCoachNotes(on: today),
                          measured: measuredToday(in: state))
        brief.workoutRequest = state.workoutRequests?[today.iso]
        brief.ftpReviewWatts = ftpProposal
        brief.plannedRoutes = calendarSessions.filter { $0.route != nil && $0.day >= today && $0.day <= today.adding(days: 7) }.map(CoachBrief.PlannedRow.init)
        return brief
    }

    private var feedbackIndex: [Day: SubjectiveFeedback] {
        Dictionary(uniqueKeysWithValues: state.feedbackByDay.values.map { ($0.day, $0) })
    }

    private var coachLocale: String { Locale.current.language.languageCode?.identifier ?? "es" }

    func isWorkoutProposalCurrent(_ proposal: AppState.WorkoutProposal) -> Bool {
        proposal.basisFingerprint == coachBrief().fingerprint
    }

    /// Today's measured signals even before the coach has answered (the Recovery row shows them).
    var measuredSignals: Readiness { measuredToday() }

    /// Asks the coach again from synchronous call sites (feedback, FTP change, plan change).
    private func reaskCoach() {
        Task { await askCoachForToday() }
    }

    /// Asks the language model for today's decision when the inputs changed since the last answer
    /// (or always, with `force`). Keeps the rule-based baseline on any failure; plan problems become `coachIssue`.
    func askCoachForToday(force: Bool = false) async {
        guard !coachThinking, !coachBusy, !isTodayWorkoutCompleted else { return }
        guard let ftp = workingFTP, ftp > 0 else {
            coachNotice = String(localized: "Add FTP in your cyclist profile to generate power-based workouts.")
            return
        }
        let day = today
        let brief = coachBrief()
        if !force, let current = state.today, current.day == day, current.aiFingerprint == brief.fingerprint {
            coachNotice = nil
            return
        }

        // Claim the request before token refresh can suspend and let another caller enter.
        coachThinking = true
        coachNotice = nil
        defer { coachThinking = false }
        guard let engine = await coachEngine() else {
            coachNotice = coachSource == nil ? nil : String(localized: "ChatGPT no longer accepts this sign-in. Sign in again in Settings → Coach.")
            return
        }
        do {
            let prescriptionFTP = workingFTP
            let prescription = try await engine.prescribe(brief: brief)
            try Task.checkCancellation()
            guard today == day, !isTodayWorkoutCompleted, coachBrief().fingerprint == brief.fingerprint else { return }
            mutate { s in
                s.acceptPrescription(prescription, day: day, ftp: prescriptionFTP)
            }
            let dropped = mergeWeekOutlook(prescription.week)
            // The merged week is itself an input to the brief; the fingerprint must describe the merged state
            // or the next refresh would ask again and loop.
            let fingerprint = coachBrief().fingerprint
            mutate { $0.today?.aiFingerprint = fingerprint }
            coachNotice = nil
            // Sessions the AI turned into rest days still exist in Intervals until deleted; the rest is re-mirrored.
            if let client {
                for id in dropped { try? await client.deleteEvent(id: id) }
            }
            await pushWeekToIntervals()
        } catch is CancellationError {
            return
        } catch let error as LLMCoachError {
            switch error {
            case .usageLimitReached: coachIssue = .usageLimit
            case .notEligible: coachIssue = .notEligible
            case .unauthorized: coachIssue = .signInAgain
            }
        } catch let error as DailyPrescription.ValidationError {
            coachNotice = String(localized: "The coach's answer failed a safety check (\(String(describing: error))). Ask again.")
        } catch let error as LLMCoach.CompletionError {
            coachNotice = coachFailureNotice(error)
        } catch {
            coachNotice = coachFailureNotice(error)
        }
    }

    /// Diagnostics stay out of the riding interface. A failed refresh does not replace the saved session.
    private func coachFailureNotice(_ error: Error, preservingSession: Bool = true) -> String {
        let message: String
        switch error as? LLMCoach.CompletionError {
        case .connection(let code) where code == URLError.notConnectedToInternet.rawValue:
            message = String(localized: "You're offline. Reconnect and ask the coach again.")
        case .connection(let code) where code == URLError.timedOut.rawValue:
            message = String(localized: "The coach took too long to respond. Please try again.")
        case .connection, .interruptedResponse:
            message = String(localized: "The coach's response was interrupted. Please try again.")
        case .httpStatus(let status) where status >= 500:
            message = String(localized: "The coach is temporarily unavailable. Please try again.")
        case .emptyResponse, .unusableAnswer:
            message = String(localized: "The coach couldn't finish a usable response. Please try again.")
        default:
            message = String(localized: "Couldn't reach the coach. Please try again.")
        }
        guard preservingSession, state.today?.day == today else { return message }
        return message + " " + String(localized: "Your saved session is still available.")
    }

    /// Folds the AI's week into the plan: today and the next seven days take the coach's kind, title and
    /// duration; completed or skipped sessions, ids and Intervals event ids are kept so the calendar updates in place.
    /// Returns the Intervals event ids of sessions that became rest days, for the caller to delete.
    @discardableResult
    private func mergeWeekOutlook(_ week: [DailyPrescription.DayOutlook]) -> [Int] {
        guard !week.isEmpty, var plan = state.plan else { return [] }
        var dropped: [Int] = []
        for outlook in week {
            if let i = plan.sessions.firstIndex(where: { $0.day == outlook.day }) {
                var session = plan.sessions[i]
                // The event itself and anything already ridden are not the coach's to move.
                guard !session.isPriority, session.status == .provisional || session.status == .generated else { continue }
                if outlook.kind == .rest {
                    if let eventID = session.intervalsEventID { dropped.append(eventID) }
                    plan.sessions.remove(at: i)
                    continue
                }
                if session.day != today, session.kind != outlook.kind || session.targetMinutes != outlook.minutes {
                    session.workout = nil
                    session.status = .provisional
                }
                session.kind = outlook.kind
                session.title = outlook.title
                session.targetMinutes = outlook.minutes
                session.targetLoad = session.workout?.estimatedLoad ?? PlanBuilder.provisionalLoad(kind: outlook.kind, minutes: outlook.minutes)
                session.note = outlook.note
                plan.sessions[i] = session
            } else if outlook.kind != .rest, outlook.minutes > 0 {
                plan.sessions.append(PlannedSession(day: outlook.day, kind: outlook.kind, title: outlook.title,
                                                    targetMinutes: outlook.minutes,
                                                    targetLoad: PlanBuilder.provisionalLoad(kind: outlook.kind, minutes: outlook.minutes), note: outlook.note))
            }
        }
        plan.sessions.sort { $0.day < $1.day }
        mutate { $0.plan = plan }
        return dropped
    }

    func recordFeeling(_ legs: SubjectiveFeedback.Legs?, motivation: Int? = nil) {
        var fb = state.feedback(for: today) ?? SubjectiveFeedback(day: today)
        fb.legs = legs
        if let motivation { fb.motivation = motivation }
        mutate { $0.setFeedback(fb) }
        reaskCoach()
    }

    // MARK: FTP

    private func recomputeFTPEstimate() {
        let since = today.adding(days: -42)
        let efforts = state.activities.filter { $0.isCycling && $0.day >= since && $0.movingTime >= 12 * 60 && ($0.intensity ?? 0) >= 85 }.count
        let estimate = FTPEstimator().estimate(curve: state.powerCurve, sustainedEfforts: efforts)
        mutate { $0.ftpEstimate = estimate }
    }

    func acceptFTP(_ watts: Int) {
        mutate { $0.acceptedFTP = watts; $0.dismissedFTPProposal = nil }
        reaskCoach()
    }

    func keepCurrentFTP() {
        mutate { $0.dismissedFTPProposal = ftpProposal }
    }

    /// Drops the locally accepted FTP so the Intervals value becomes the working FTP again.
    func useIntervalsFTP() {
        mutate { $0.acceptedFTP = nil; $0.dismissedFTPProposal = nil }
        reaskCoach()
    }

    // MARK: Plan

    func beginPlanConsultation() async {
        if state.planConsultation == nil { mutate { $0.planConsultation = .init(startedOn: today) } }
        guard state.planConsultation?.reply == nil || state.planConsultation?.messages.last?.role == .athlete else { return }
        await requestPlanConsultation()
    }

    func restartPlanConsultation() async {
        consultationRequestID = nil
        consultationBusy = false
        consultationError = nil
        mutate { $0.planConsultation = .init(startedOn: today) }
        await requestPlanConsultation()
    }

    func cancelPlanConsultationRequest() {
        consultationRequestID = nil
        consultationBusy = false
    }

    func sendPlanConsultationAnswer(_ text: String) async {
        let answer = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty, answer.count <= 6000, !consultationBusy, state.planConsultation != nil else { return }
        mutate {
            $0.planConsultation?.messages.append(.init(role: .athlete, text: answer))
            // A previous draft cannot be accepted while a requested revision is outstanding or failed.
            $0.planConsultation?.reply?.draft = nil
        }
        await requestPlanConsultation()
    }

    func requestPlanConsultation() async {
        guard !consultationBusy, let session = state.planConsultation else { return }
        let requestID = UUID(), account = athleteID, day = today
        consultationRequestID = requestID
        consultationBusy = true
        consultationError = nil
        defer { if consultationRequestID == requestID { consultationBusy = false } }
        let context = PlanConsultation.Context(today: day, locale: coachLocale, ftp: workingFTP,
            weightKg: state.weightKg, heightCm: state.heightCm, profileSummary: state.cyclistProfile?.summary,
            lastSyncAt: state.lastSyncAt, historyIssue: syncError, activities: state.activities,
            wellness: state.wellness, powerCurve: state.powerCurve, existingPlan: state.plan, session: session)
        func isCurrent() -> Bool {
            !Task.isCancelled && isSignedIn && athleteID == account && today == day &&
            consultationRequestID == requestID && state.planConsultation?.id == session.id
        }
        guard let engine = await coachEngine() else {
            if isCurrent() { consultationError = String(localized: "Connect ChatGPT (or an API key) in Settings → Coach first.") }
            return
        }
        do {
            let reply = try await engine.consult(context)
            guard isCurrent() else { return }
            mutate {
                $0.planConsultation?.reply = reply
                $0.planConsultation?.messages.append(.init(role: .coach, text: reply.question))
            }
        } catch is CancellationError { return }
        catch let error as LLMCoachError {
            guard isCurrent() else { return }
            switch error {
            case .usageLimitReached: coachIssue = .usageLimit
            case .notEligible: coachIssue = .notEligible
            case .unauthorized: coachIssue = .signInAgain
            }
            consultationError = String(localized: "The coach needs attention. Your consultation is saved; try again after reconnecting.")
        } catch is PlanConsultation.ValidationError {
            if isCurrent() { consultationError = String(localized: "The coach couldn't prepare a valid consultation reply. Your answers are saved. Try again.") }
        } catch {
            if isCurrent() { consultationError = coachFailureNotice(error, preservingSession: false) }
        }
    }

    func saveCyclistProfile(_ update: PlanConsultation.ProfileUpdate) async throws {
        try update.validate()
        let now = Date()
        mutate {
            var current = $0.cyclistMeasurements ?? CyclistMeasurements()
            current.merge(.init(weight: update.weightKg.map { .init(value: $0, measuredAt: now, source: .athlete) },
                                height: update.heightCm.map { .init(value: $0, measuredAt: now, source: .athlete) }))
            $0.cyclistMeasurements = current
            if let kg = update.weightKg { $0.profileWeightPendingSync = .init(day: today, kg: kg) }
            if let ftp = update.ftp { $0.acceptedFTP = ftp; $0.dismissedFTPProposal = nil }
            $0.planConsultation?.reply?.profileUpdate = nil
        }
        await syncProfileWeight()
        reaskCoach()
    }

    func importCyclistMeasurements() async throws -> Bool {
        let account = athleteID
        try await health.requestAuthorization()
        let measurements = try await health.readBodyMeasurements()
        guard account == athleteID, isSignedIn else { return false }
        var current = state.cyclistMeasurements ?? CyclistMeasurements()
        current.merge(measurements)
        guard current != state.cyclistMeasurements, current.weight != nil || current.height != nil else { return false }
        mutate { $0.cyclistMeasurements = current }
        return true
    }

    private func syncProfileWeight() async {
        guard !syncingProfileWeight, let pending = state.profileWeightPendingSync, let client else { return }
        syncingProfileWeight = true
        defer { syncingProfileWeight = false }
        let account = athleteID
        do {
            try await client.updateWellness(WellnessDay(day: pending.day, weightKg: pending.kg))
            guard account == athleteID, isSignedIn, state.profileWeightPendingSync == pending else { return }
            mutate { $0.profileWeightPendingSync = nil }
        } catch { /* Kept for retry on refresh; the profile editor shows the pending sync. */ }
    }

    /// Explicit acceptance is the only place a consultation can replace an active plan.
    func activateConsultationPlan(_ draft: PlanConsultation.Draft, sessionID: UUID) async throws {
        await acquireCalendar()
        do {
            defer { releaseCalendar() }
            guard isSignedIn, !consultationBusy, !Task.isCancelled, state.planConsultation?.id == sessionID,
                  state.planConsultation?.reply?.draft == draft else { throw PlanConsultation.ValidationError.invalidDraft }
            var plan = try draft.makePlan(today: today)
            let previous = state.plan?.sessions ?? []
            let completedToday = isTodayWorkoutCompleted
            var reused = Set<Int>()
            for i in plan.sessions.indices {
                if let old = previous.first(where: { $0.day == plan.sessions[i].day }), let id = old.intervalsEventID {
                    plan.sessions[i].intervalsEventID = id
                    reused.insert(id)
                }
            }
            plan.isActive = true
            mutate {
                let retired = previous.filter { $0.day >= today && $0.status != .completed }
                    .compactMap(\.intervalsEventID).filter { !reused.contains($0) }
                $0.retiredPlanEventIDs = Array(Set(($0.retiredPlanEventIDs ?? []) + retired))
                $0.plan = plan
                if !completedToday { $0.today = nil }
                $0.planConsultation = nil
            }
        }
        await retirePlanEvents()
        await askCoachForToday()
        await pushWeekToIntervals()
    }

    private func retirePlanEvents() async {
        guard state.retiredPlanEventIDs?.isEmpty == false else { return }
        await acquireCalendar()
        defer { releaseCalendar() }
        guard let client, !Task.isCancelled else { return }
        let account = athleteID
        for id in state.retiredPlanEventIDs ?? [] {
            do {
                try await client.deleteEvent(id: id)
            } catch HTTPError.status(404, _) {
                // A preceding mirror or retry already removed this session.
            } catch { return }
            guard account == athleteID, isSignedIn else { return }
            mutate { $0.retiredPlanEventIDs?.removeAll { $0 == id } }
        }
    }

    func createPlan(_ request: PlanBuilder.Request) async {
        var plan = PlanBuilder().build(request)
        plan.isActive = true
        mutate { $0.plan = plan }
        await askCoachForToday()
        await pushWeekToIntervals()
    }

    func discardPlan() async {
        guard let plan = state.plan else { return }
        if let client {
            for s in plan.sessions where s.day >= today {
                if let eventID = s.intervalsEventID { try? await client.deleteEvent(id: eventID) }
            }
        }
        mutate { $0.plan = nil }
        await askCoachForToday()
    }

    func applyIntent(_ intent: CoachIntent, messageID: UUID?) async {
        guard intent.needsClarification.isEmpty, !coachBusy, !coachThinking,
              let messageID, let message = state.coachMessages.first(where: { $0.id == messageID }),
              message.intent == intent, !message.applied else { return }
        var updated = state
        if let request = intent.workoutRequest {
            guard request.day >= today, !state.isWorkoutCompleted(on: request.day) else { return }
            if request.day == today {
                guard !isTodayWorkoutCompleted, let proposal = message.workoutProposal,
                      proposal.basisFingerprint == coachBrief().fingerprint else {
                    coachNotice = String(localized: "Your training context changed. Ask the coach for an updated workout preview.")
                    return
                }
                updated.applyCoachIntent(intent, on: today)
                updated.acceptPrescription(proposal.prescription, day: today, ftp: proposal.ftp)
            } else {
                updated.applyCoachIntent(intent, on: today)
                // A future request changes the day's intent, not a previously generated concrete workout.
                if let i = updated.plan?.sessions.firstIndex(where: { $0.day == request.day && $0.status != .completed && $0.status != .skipped }) {
                    updated.plan?.sessions[i].workout = nil
                    updated.plan?.sessions[i].status = .provisional
                }
            }
        } else {
            updated.applyCoachIntent(intent, on: today)
        }
        if let i = updated.coachMessages.firstIndex(where: { $0.id == messageID }) { updated.coachMessages[i].applied = true }
        mutate { $0 = updated }
        if intent.workoutRequest?.day == today {
            let fingerprint = coachBrief().fingerprint
            mutate { $0.today?.aiFingerprint = fingerprint }
            coachNotice = nil
        } else { await askCoachForToday() }
        await pushWeekToIntervals()
    }

    /// Mirrors the next seven days to the Intervals calendar so other tools (and the athlete's watch) see them.
    /// Mirrors the next week of the plan to the Intervals calendar, exactly one event per session.
    /// Leftover Cadencia events (from a reinstall or an earlier plan) are deleted first, because Intervals
    /// counts every planned workout dated today in today's fitness and fatigue.
    func pushWeekToIntervals() async {
        await acquireCalendar()
        defer { releaseCalendar() }
        guard !Task.isCancelled, let client, let ftp = workingFTP else { return }
        let account = athleteID
        let allSessions = calendarSessions
        guard !allSessions.isEmpty else { return }
        let horizon = today.adding(days: 7)
        let retained = allSessions.filter { $0.day >= today && $0.kind != .rest && $0.status != .skipped }
        let sessions = retained.filter { $0.day <= horizon && $0.status != .completed }
        do {
            // A failed read aborts the write pass. Never blindly create when reconciliation failed.
            let events = try await client.events(oldest: today, newest: today.adding(days: 14))
            guard athleteID == account, isSignedIn else { return }
            for stale in PlanMirror.staleEvents(events, sessions: retained) {
                try await client.deleteEvent(id: stale.id)
            }
            for session in sessions {
                guard athleteID == account, isSignedIn, !Task.isCancelled else { return }
                let existing = PlanMirror.existingEvent(for: session, in: events)
                let (prepared, targetFTP) = calendarSession(session, fallbackFTP: ftp)
                var reconciled = prepared
                // A stored id may have been removed externally; the fresh calendar read wins.
                reconciled.intervalsEventID = existing?.id
                let event = try await client.upsertPlannedWorkout(reconciled, ftp: targetFTP, existingEventID: existing?.id)
                guard athleteID == account, isSignedIn else { return }
                saveCalendarEvent(event.id, session: prepared, ftp: targetFTP)
            }
            // Mirroring changes today's projected load. Refresh it before displaying the result.
            let days = try await client.wellness(oldest: today, newest: today)
            if athleteID == account, isSignedIn { mutate { $0.mergeWellness(days) } }
        } catch {
            syncError = "Intervals calendar: \(error.localizedDescription)"
            return
        }
    }

    /// All calendar writes share this lock, including explicit outdoor sends. A queued send must
    /// wait for the fresh reconciliation read, rather than treating an in-flight mirror as success.
    private func acquireCalendar() async {
        if isMirroring {
            await withCheckedContinuation { calendarWaiters.append($0) }
        } else { isMirroring = true }
    }

    private func releaseCalendar() {
        if calendarWaiters.isEmpty { isMirroring = false }
        else { calendarWaiters.removeFirst().resume() }
    }

    private var calendarSessions: [PlannedSession] {
        var sessions = state.plan?.sessions ?? []
        let planDays = Set(sessions.map(\.day))
        sessions.append(contentsOf: (state.standaloneSessions ?? []).filter { !planDays.contains($0.day) })
        return sessions.map { state.session(on: $0.day) ?? $0 }
    }

    var todayRideLocation: RideLocation { state.today?.rideLocation ?? plannedToday?.location ?? .indoor }
    var outdoorFTP: Int? { state.acceptedFTP ?? state.athlete?.ftp ?? workingFTP }

    var outdoorWorkout: OutdoorWorkout? {
        guard let workout = todayWorkout, !workout.steps.isEmpty, workout.kind != .rest, workout.kind != .strength,
              let ftp = outdoorFTP, ftp > 0 else { return nil }
        return OutdoorWorkout(workout: workout, prescriptionFTP: state.today?.prescriptionFTP ?? workingFTP ?? ftp, outdoorFTP: ftp)
    }

    var outdoorRevision: String? { outdoorWorkout?.revision(on: today) }
    var currentOutdoorHandoff: AppState.OutdoorHandoff? {
        guard todayRideLocation == .outdoor, let handoff = state.today?.outdoorHandoff,
              handoff.revision == outdoorRevision else { return nil }
        return handoff
    }

    func setTodayRideLocation(_ location: RideLocation) {
        guard todayWorkout != nil, !isTodayWorkoutCompleted else { return }
        mutate { s in
            s.today?.rideLocation = location
            if let i = s.plan?.sessions.firstIndex(where: { $0.day == today }) {
                s.plan?.sessions[i].location = location
            } else if let i = s.standaloneSessions?.firstIndex(where: { $0.day == today }) {
                s.standaloneSessions?[i].location = location
            } else if let workout = s.today?.workout {
                let ftp = s.today?.prescriptionFTP ?? s.workingFTP
                let session = PlannedSession(day: today, kind: workout.kind, title: workout.name,
                    targetMinutes: Int(workout.totalDuration / 60), status: .generated, workout: workout, location: location,
                    prescriptionFTP: ftp)
                if s.standaloneSessions == nil { s.standaloneSessions = [] }
                s.standaloneSessions?.append(session)
            }
        }
        Task { await pushWeekToIntervals() }
    }

    private func calendarSession(_ raw: PlannedSession, fallbackFTP: Int) -> (PlannedSession, Int) {
        var session = raw
        if raw.day == today, let workout = todayWorkout {
            session.workout = workout
            session.title = workout.name
            session.location = todayRideLocation
            session.prescriptionFTP = state.today?.prescriptionFTP ?? raw.prescriptionFTP ?? fallbackFTP
        }
        guard session.location == .outdoor, let workout = session.workout else { return (session, fallbackFTP) }
        let ftp = outdoorFTP ?? fallbackFTP
        let prepared = OutdoorWorkout(workout: workout, prescriptionFTP: session.prescriptionFTP ?? fallbackFTP, outdoorFTP: ftp)
        session.workout = prepared.workout
        return (session, ftp)
    }

    private func saveCalendarEvent(_ id: Int, session: PlannedSession, ftp: Int) {
        mutate { s in
            if let i = s.plan?.sessions.firstIndex(where: { $0.id == session.id }) {
                s.plan?.sessions[i].intervalsEventID = id
                if session.location == .outdoor {
                    s.plan?.sessions[i].deliveredWorkout = session.workout
                    s.plan?.sessions[i].deliveredFTP = ftp
                }
            }
            if let i = s.standaloneSessions?.firstIndex(where: { $0.id == session.id }) {
                s.standaloneSessions?[i].intervalsEventID = id
                if session.location == .outdoor {
                    s.standaloneSessions?[i].deliveredWorkout = session.workout
                    s.standaloneSessions?[i].deliveredFTP = ftp
                }
            }
        }
    }

    /// Saves the latest concrete session. This acknowledges Intervals only, never receipt by Garmin.
    func sendOutdoorWorkout() async throws {
        await acquireCalendar()
        defer { releaseCalendar() }
        try Task.checkCancellation()
        guard !isTodayWorkoutCompleted, let client, let prepared = outdoorWorkout, todayRideLocation == .outdoor,
              let session = calendarSessions.first(where: { $0.day == today && $0.status != .completed && $0.status != .skipped }) else {
            throw OutdoorError.noSession
        }
        let account = athleteID, day = today, revision = prepared.revision(on: day)
        let events = try await client.events(oldest: day, newest: day)
        guard athleteID == account, isSignedIn, today == day, outdoorRevision == revision,
              !isTodayWorkoutCompleted else { throw OutdoorError.changed }
        var wire = session
        wire.workout = prepared.workout
        wire.title = prepared.workout.name
        wire.location = .outdoor
        wire.intervalsEventID = PlanMirror.existingEvent(for: session, in: events)?.id
        let event = try await client.upsertPlannedWorkout(wire, ftp: prepared.ftp, existingEventID: wire.intervalsEventID)
        guard athleteID == account, isSignedIn else { throw OutdoorError.changed }
        // Persist the server id even if the coach changed the workout while the write was in flight.
        saveCalendarEvent(event.id, session: wire, ftp: prepared.ftp)
        guard today == day, outdoorRevision == revision, todayRideLocation == .outdoor,
              !isTodayWorkoutCompleted else { throw OutdoorError.changed }
        mutate { $0.today?.outdoorHandoff = .init(revision: revision, eventID: event.id, savedAt: Date()) }
    }

    func exportOutdoorFIT() async throws -> URL {
        try await sendOutdoorWorkout()
        guard let handoff = currentOutdoorHandoff, let client else { throw OutdoorError.changed }
        let account = athleteID, day = today
        let data = try await client.plannedWorkoutFIT(eventID: handoff.eventID, day: day)
        guard athleteID == account, isSignedIn, today == day,
              currentOutdoorHandoff?.revision == handoff.revision, !isTodayWorkoutCompleted else { throw OutdoorError.changed }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("Cadencia-\(day.iso).fit")
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    enum OutdoorError: LocalizedError {
        case noSession, changed
        var errorDescription: String? {
            switch self {
            case .noSession: return String(localized: "Choose Outdoor for an unfinished cycling workout and connect Intervals.icu first.")
            case .changed: return String(localized: "The workout or account changed. Prepare the latest session again.")
            }
        }
    }

    // MARK: Coach

    /// The only automatic caller is the Home screen's first appearance with both connections.
    /// Sync, daily prescriptions, plan changes and model changes never regenerate this snapshot.
    func generateCyclistProfile(automatically: Bool = false) async {
        guard !cyclistProfileBusy else { return }
        if automatically {
            guard CyclistProfile.shouldGenerateAutomatically(hasReport: state.cyclistProfile != nil,
                                                              attemptedAt: state.cyclistProfileAutomaticAttemptedAt),
                  client != nil, aiCoachAvailable else { return }
        }
        guard let client, let account = state.athlete?.id, let connection = credential else {
            cyclistProfileError = String(localized: "Connect Intervals.icu in Settings to build your cyclist profile.")
            return
        }
        guard aiCoachAvailable else {
            cyclistProfileError = String(localized: "Connect ChatGPT (or an API key) in Settings → Coach first.")
            return
        }
        cyclistProfileBusy = true
        cyclistProfileError = nil
        if automatically { mutate { $0.cyclistProfileAutomaticAttemptedAt = Date() } }
        defer { cyclistProfileBusy = false }
        func sameAccount() -> Bool { athleteID == account && credential == connection }
        do {
            let brief = try await client.cyclistProfileBrief(newest: today, locale: coachLocale)
            try Task.checkCancellation()
            guard sameAccount() else { return }
            guard let engine = await coachEngine() else {
                if sameAccount() { cyclistProfileError = String(localized: "Connect ChatGPT (or an API key) in Settings → Coach first.") }
                return
            }
            guard sameAccount() else { return }
            let report = try await engine.cyclistProfile(brief)
            try Task.checkCancellation()
            guard sameAccount() else { return }
            mutate { $0.cyclistProfile = report }
        } catch is CancellationError {
            return
        } catch let error as LLMCoachError {
            guard sameAccount() else { return }
            switch error {
            case .usageLimitReached: coachIssue = .usageLimit
            case .notEligible: coachIssue = .notEligible
            case .unauthorized: coachIssue = .signInAgain
            }
            cyclistProfileError = String(localized: "The coach connection needs attention. Your saved profile is still available if you have one.")
        } catch let error as HTTPError {
            guard sameAccount() else { return }
            cyclistProfileError = error.isAuthFailure
                ? String(localized: "Intervals rejected the credential. Reconnect in Settings.")
                : String(localized: "Couldn't read your Intervals.icu history. Try generating your profile again.")
        } catch {
            guard sameAccount() else { return }
            cyclistProfileError = coachFailureNotice(error, preservingSession: false)
        }
    }

    func sendToCoach(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !coachBusy else { return }
        coachBusy = true
        coachNotice = nil
        defer { coachBusy = false }
        let source = AppState.CoachMessage(role: .athlete, text: trimmed)
        let account = athleteID
        let day = today
        let context = CoachContext(today: today, locale: Locale.current.language.languageCode?.identifier ?? "es",
                                   readiness: readiness, plan: state.plan, recentActivities: Array(state.activities.suffix(10)), ftp: workingFTP,
                                   workout: todayWorkout, recentConversation: state.coachMessages.suffix(8).map { "\($0.role.rawValue): \($0.text)" })
        mutate { $0.coachMessages.append(source) }
        // When the ChatGPT refresh token is dead `freshChatGPTCredential` sets `coachIssue = .signInAgain`;
        // the Coach screen shows that as a banner with a sign-in action.
        guard let engine = await coachEngine() else {
            mutate { $0.coachMessages.append(.init(role: .coach, text: String(localized: "Connect ChatGPT (or an API key) in Settings → Coach first."))) }
            return
        }
        do {
            let intent = try await engine.interpret(trimmed, context: context)
            var proposal: AppState.WorkoutProposal?
            if let request = intent.workoutRequest, request.day == day, !isTodayWorkoutCompleted, workingFTP != nil {
                let basis = coachBrief().fingerprint
                let brief = coachBrief(applying: intent)
                let prescription = try await engine.prescribe(brief: brief)
                proposal = .init(prescription: prescription, basisFingerprint: basis, ftp: brief.athlete.ftp)
            }
            guard athleteID == account, today == day else { return }
            mutate { $0.coachMessages.append(.init(role: .coach, text: proposal?.prescription.note.session ?? intent.reply, intent: intent,
                                                  sourceMessageID: source.id, workoutProposal: proposal)) }
        } catch let error as LLMCoachError {
            guard athleteID == account, today == day else { return }
            let text: String
            switch error {
            case .usageLimitReached:
                coachIssue = .usageLimit
                text = String(localized: "You've reached the usage limit of your ChatGPT plan for now. Check it under Manage usage, or wait for it to reset.")
            case .notEligible:
                coachIssue = .notEligible
                text = String(localized: "Your ChatGPT account can't share its plan with apps. You can use an API key instead in Settings → Coach.")
            case .unauthorized:
                coachIssue = .signInAgain
                text = String(localized: "ChatGPT no longer accepts this sign-in. Sign in again in Settings → Coach.")
            }
            mutate { $0.coachMessages.append(.init(role: .coach, text: text)) }
        } catch is DailyPrescription.ValidationError {
            guard athleteID == account, today == day else { return }
            let notice = String(localized: "The coach couldn't produce a valid workout for this request. Your current workout is unchanged. Try rephrasing the request.")
            mutate { $0.coachMessages.append(.init(role: .coach, text: notice)) }
        } catch is CancellationError {
            return
        } catch {
            guard athleteID == account, today == day else { return }
            let notice = coachFailureNotice(error, preservingSession: false)
            mutate { $0.coachMessages.append(.init(role: .coach, text: notice)) }
        }
    }

    func clearCoachHistory() { mutate { $0.coachMessages = [] } }

    // MARK: Rides

    /// Navigation data is local; only compact course metrics are passed to the coach.
    func attachRideRoute(_ route: GPXRoute, source: Data, fileName: String, sourceIndex: Int, day: Day, minutes: Int) async throws {
        let account = athleteID
        let sessionID = state.session(on: day)?.id
        guard day >= today, !state.isWorkoutCompleted(on: day),
              state.session(on: day).map({ $0.kind != .rest && $0.kind != .strength && $0.status != .skipped }) ?? true else { throw OutdoorError.changed }
        let sourceURL = store.url("routes/\(route.id.uuidString).gpx")
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.createDirectory(at: sourceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try source.write(to: sourceURL, options: [.atomic, .completeFileProtection])
        }.value
        try Task.checkCancellation()
        guard athleteID == account, !state.isWorkoutCompleted(on: day), day >= today,
              state.session(on: day)?.id == sessionID,
              state.session(on: day).map({ $0.kind != .rest && $0.kind != .strength && $0.status != .skipped }) ?? true else { throw OutdoorError.changed }
        mutate { state in
            if state.rideRoutePlans == nil { state.rideRoutePlans = [:] }
            state.rideRoutePlans?[day.iso] = .init(route: route, fileName: fileName, sourceIndex: sourceIndex, minutes: minutes)
            var session = state.session(on: day) ?? PlannedSession(day: day, kind: .endurance, title: route.name.isEmpty ? String(localized: "Outdoor ride") : route.name,
                targetMinutes: minutes, location: .outdoor)
            // The day attachment owns the measured profile once. session(on:) supplies it to readers.
            session.route = nil; session.routeFileName = nil; session.routeSourceIndex = nil; session.location = .outdoor
            if let i = state.plan?.sessions.firstIndex(where: { $0.id == session.id }) { state.plan?.sessions[i] = session }
            else {
                if state.standaloneSessions == nil { state.standaloneSessions = [] }
                if let i = state.standaloneSessions?.firstIndex(where: { $0.id == session.id }) { state.standaloneSessions?[i] = session }
                else { state.standaloneSessions?.append(session) }
            }
            if day == today { state.today?.rideLocation = .outdoor }
        }
        Task { await askCoachForToday(); await pushWeekToIntervals() }
    }

    func removeRideRoute(on day: Day) {
        guard !state.isWorkoutCompleted(on: day) else { return }
        mutate { state in
            state.rideRoutePlans?[day.iso] = nil
            if let i = state.plan?.sessions.firstIndex(where: { $0.day == day }) {
                state.plan?.sessions[i].route = nil; state.plan?.sessions[i].routeFileName = nil; state.plan?.sessions[i].routeSourceIndex = nil
            }
            if let i = state.standaloneSessions?.firstIndex(where: { $0.day == day }) {
                state.standaloneSessions?[i].route = nil; state.standaloneSessions?[i].routeFileName = nil; state.standaloneSessions?[i].routeSourceIndex = nil
            }
        }
    }

    func exportRideRoute(on day: Day) async throws -> URL {
        guard let attachment = state.routePlan(on: day) else { throw OutdoorError.noSession }
        let route = attachment.route
        let account = athleteID, sourceURL = store.url("routes/\(route.id.uuidString).gpx"), index = attachment.sourceIndex
        let url = try await Task.detached(priority: .userInitiated) {
            let data = try GPXExporter.selectedRoute(from: Data(contentsOf: sourceURL), index: index)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Cadencia-route-\(day.iso).gpx")
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            return url
        }.value
        guard athleteID == account, state.routePlan(on: day)?.route.id == route.id else { throw OutdoorError.changed }
        return url
    }

    /// Fetch actual GPS automatically on review, cache locally, and keep failures independent of AI notes.
    func loadRideRoute(_ rideID: UUID, retry: Bool = false) async {
        guard let ride = ride(id: rideID), ride.athleteID == athleteID, ride.sourceActivity != nil,
              ride.recordedRoute == nil, rideRouteStatus[rideID] != .loading else { return }
        if !retry, ride.recordedRouteCheckedAt != nil { rideRouteStatus[rideID] = .unavailable; return }
        guard let client, let activityID = ride.sourceActivity?.id else {
            rideRouteStatus[rideID] = .failed(String(localized: "Connect Intervals.icu to load the recorded GPS route.")); return
        }
        let account = athleteID
        rideRouteStatus[rideID] = .loading
        defer { if rideRouteStatus[rideID] == .loading { rideRouteStatus[rideID] = nil } }
        do {
            let source = try await client.activityGPX(id: activityID)
            let routes = try await Task.detached(priority: .userInitiated) { try GPXImporter().parse(source, combineTracks: true) }.value
            try Task.checkCancellation()
            guard athleteID == account, isSignedIn, var latest = self.ride(id: rideID) else { return }
            // One provider activity; preserve separate recording segments across pauses/gaps.
            guard routes.count == 1 else { throw GPXImporter.ImportError.noRoute }
            latest.recordedRoute = routes[0]; latest.recordedRouteCheckedAt = Date()
            try store.save(latest, at: "rides/\(rideID.uuidString).json")
            rideCache[rideID] = latest; rideRouteStatus[rideID] = nil
        } catch is CancellationError {
            rideRouteStatus[rideID] = nil
        } catch {
            guard athleteID == account else { rideRouteStatus[rideID] = nil; return }
            rideRouteStatus[rideID] = .failed(String(localized: "The recorded GPS route is not available from Intervals.icu. Retry after the activity finishes syncing, or import its recorded GPX."))
        }
    }

    func attachRecordedRoute(_ route: GPXRoute, to rideID: UUID) throws {
        guard var ride = ride(id: rideID), ride.athleteID == athleteID else { throw OutdoorError.changed }
        ride.recordedRoute = route; ride.recordedRouteCheckedAt = Date()
        try store.save(ride, at: "rides/\(rideID.uuidString).json")
        rideCache[rideID] = ride; rideRouteStatus[rideID] = nil
    }

    /// Head-unit rides are already in Intervals. Save a local review record without ever enqueuing
    /// an upload or writing another Health workout. Stable ids make repeated refreshes idempotent.
    private func importOutdoorRides(_ activities: [ActivitySummary]) throws {
        let sessions = calendarSessions
        for activity in activities {
            guard activity.externalID?.hasPrefix("cadencia-") != true,
                  !state.ledger.entries.contains(where: { $0.intervalsActivityID == activity.id }) else { continue }
            let id = OutdoorRideImport.recordingID(athleteID: athleteID, activityID: activity.id)
            let previous = ride(id: id)
            guard let ride = OutdoorRideImport.recording(activity: activity, sessions: sessions, athleteID: athleteID,
                fallbackFTP: outdoorFTP ?? 200, existing: previous) else { continue }
            if previous == ride { continue }
            try store.save(ride, at: "rides/\(id.uuidString).json")
            rideCache[id] = ride
            mutate { s in
                let entry = AppState.RideIndexEntry(id: id, name: activity.name, kind: ride.workout.kind, startedAt: activity.startDateLocal,
                    duration: activity.movingTime, averageWatts: activity.averageWatts, load: activity.trainingLoad)
                if let i = s.rideIndex.firstIndex(where: { $0.id == id }) { s.rideIndex[i] = entry } else { s.rideIndex.append(entry) }
                s.completeSession(for: ride)
            }
        }
    }

    func ride(id: UUID) -> RideRecording? {
        if let r = rideCache[id] { return r }
        let r = store.load(RideRecording.self, at: "rides/\(id.uuidString).json")
        if let r { rideCache[id] = r }
        return r
    }

    func finishRide(_ recording: RideRecording) async {
        guard recording.sourceActivity == nil else { return }
        rideCache[recording.id] = recording
        do { try store.save(recording, at: "rides/\(recording.id.uuidString).json") } catch { syncError = error.localizedDescription }
        let ftp = workingFTP ?? 200
        mutate {
            if !$0.rideIndex.contains(where: { $0.id == recording.id }) {
                $0.rideIndex.append(.init(id: recording.id, name: recording.workout.name, kind: recording.workout.kind, startedAt: recording.startedAt,
                                      duration: recording.duration, averageWatts: recording.averageWatts, load: recording.trainingLoad(ftp: ftp)))
            }
            $0.ledger.enqueue(rideID: recording.id, athleteID: recording.athleteID)
            $0.completeSession(for: recording)
        }
        if state.settings.writeWorkoutsToHealth {
            try? await health.saveWorkout(recording, ftp: ftp)
        }
        await runUploads()
    }

    func submitReview(rideID: UUID, rpe: Int?, legs: SubjectiveFeedback.Legs?) async {
        guard var ride = ride(id: rideID) else { return }
        var fb = state.feedback(for: Day(ride.startedAt)) ?? SubjectiveFeedback(day: Day(ride.startedAt))
        fb.rpe = rpe
        fb.legs = legs
        ride.feedback = fb
        rideCache[rideID] = ride
        try? store.save(ride, at: "rides/\(rideID.uuidString).json")
        mutate { $0.setFeedback(fb) }
        await syncFeedback(for: rideID)
    }

    private func syncFeedback(for rideID: UUID) async {
        guard let client, let entry = state.ledger.entry(for: rideID), entry.state == .confirmed, !entry.feedbackSynced,
              let activityID = entry.intervalsActivityID, let fb = ride(id: rideID)?.feedback else { return }
        let feel: Int? = fb.legs.map { $0 == .fresh ? 1 : ($0 == .ok ? 3 : 5) }
        if (try? await client.updateActivityFeedback(activityID: activityID, rpe: fb.rpe, feel: feel)) != nil {
            mutate { $0.ledger.markFeedbackSynced(rideID) }
        }
    }

    func runUploads() async {
        guard let client, !isUploading else { return }
        isUploading = true
        defer { isUploading = false }
        let now = Date()
        for entry in state.ledger.due(for: athleteID, now: now) {
            guard let ride = ride(id: entry.rideID), ride.sourceActivity == nil else { continue }
            mutate { $0.ledger.markAttempt(entry.rideID, at: now) }
            do {
                let result = try await client.uploadActivity(ride)
                mutate { $0.ledger.markConfirmed(entry.rideID, activityID: result.activityID, at: Date()) }
                await syncFeedback(for: entry.rideID)
                Task { await debriefRide(entry.rideID) }
            } catch let error as HTTPError {
                mutate { $0.ledger.markFailure(entry.rideID, error: error, requestWasSent: true) }
            } catch {
                mutate { $0.ledger.markFailure(entry.rideID, error: .transport(error.localizedDescription), requestWasSent: true) }
            }
        }
    }

    // MARK: Post-ride debrief

    /// The most recent ride on this phone from the last few days, for the "Last session" card on Today.
    var lastRide: AppState.RideIndexEntry? {
        let cutoff = today.adding(days: -3).date()
        return state.rideIndex.filter { $0.startedAt >= cutoff }.max { $0.startedAt < $1.startedAt }
    }

    /// Debriefs confirmed rides that never got one (the app was closed while the coach was writing, or
    /// the upload only went through on a later refresh).
    private func debriefRecentRides() {
        let cutoff = today.adding(days: -3).date()
        for entry in state.rideIndex {
            guard let ride = ride(id: entry.id), ride.athleteID == athleteID,
                  state.ledger.entry(for: entry.id)?.state == .confirmed || ride.sourceActivity != nil else { continue }
            if RideDebrief.requiresRefresh(ride) {
                if entry.startedAt >= cutoff { Task { await debriefRide(entry.id) } }
            } else if ride.debrief != nil, ride.debriefNote == nil {
                // Retry pending Notes even when the original session is older than the debrief window.
                Task { await syncDebriefNote(for: entry.id) }
            } else if entry.startedAt >= cutoff, (ride.sourceActivity == nil || ride.plannedSessionID != nil), debriefStatus[entry.id] == nil, ride.debrief == nil, ride.debriefNote == nil {
                Task { await debriefRide(entry.id) }
            }
        }
    }

    /// Read Notes back for details, or save a pending local debrief. A saved report never needs
    /// another AI request just because its Intervals write failed or the app was closed.
    func syncDebriefNote(for rideID: UUID) async {
        guard !syncingDebriefNotes.contains(rideID), let client, let ride = ride(id: rideID),
              ride.athleteID == athleteID, !RideDebrief.requiresRefresh(ride) else { return }
        let entry = state.ledger.entry(for: rideID)
        guard let activityID = ride.sourceActivity?.id ?? (entry?.state == .confirmed ? entry?.intervalsActivityID : nil) else { return }
        syncingDebriefNotes.insert(rideID)
        defer { syncingDebriefNotes.remove(rideID) }
        do {
            let note: IntervalsActivityNote?
            if let report = ride.debrief {
                note = try await client.saveDebriefNote(activityID: activityID, report: report)
            } else {
                note = try await client.activityNotes(activityID: activityID).filter(\.isCoachDebrief).max { $0.id < $1.id }
            }
            guard isSignedIn, athleteID == ride.athleteID, var latest = self.ride(id: rideID) else { return }
            // A report may have been refreshed while Notes were being read. Never attach an old note to it.
            if let report = latest.debrief, note?.content != report.noteContent { return }
            latest.debriefNote = note
            try store.save(latest, at: "rides/\(rideID.uuidString).json")
            rideCache[rideID] = latest
            debriefNoteErrors[rideID] = nil
        } catch {
            guard isSignedIn, athleteID == ride.athleteID else { return }
            if (error as? HTTPError)?.isAuthFailure == true {
                debriefNoteErrors[rideID] = String(localized: "Reconnect Intervals.icu in Settings to allow access to activity Notes. Your saved debrief is still available.")
            } else {
                debriefNoteErrors[rideID] = String(localized: "The coach note could not sync with Intervals. Your saved debrief is still available. Try again when connected.")
            }
        }
    }

    /// Asks the coach for the session's debrief: waits for Intervals to finish processing the upload,
    /// fetches its analysis, then hands the recording and that analysis to the coach. The answer is kept
    /// on the ride file; failures are kept in `debriefStatus` so the screen can offer a retry.
    func debriefRide(_ rideID: UUID) async {
        guard let client, var ride = ride(id: rideID), ride.athleteID == athleteID else { return }
        let entry = state.ledger.entry(for: rideID)
        guard let activityID = ride.sourceActivity?.id ?? (entry?.state == .confirmed ? entry?.intervalsActivityID : nil) else { return }
        switch debriefStatus[rideID] {
        case .waitingForIntervals, .reading: return
        case .failed, nil: break
        }
        let refreshing = RideDebrief.requiresRefresh(ride)
        if !refreshing, ride.debrief != nil || ride.debriefNote != nil {
            await syncDebriefNote(for: rideID)
            return
        }
        debriefStatus[rideID] = .waitingForIntervals
        if !refreshing { await syncDebriefNote(for: rideID) }
        guard isSignedIn, athleteID == ride.athleteID else { debriefStatus[rideID] = nil; return }
        if !refreshing, self.ride(id: rideID)?.debriefNote != nil { debriefStatus[rideID] = nil; return }

        // Intervals analyses an upload within seconds; the numbers are only there once `analyzed` flips.
        var analysis: ActivityDetail?
        var analysisReadFailed = false
        var attempt = 0
        while analysis == nil, attempt < 8 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(3)) }
            attempt += 1
            do {
                let detail = try await client.activityDetail(id: activityID)
                analysisReadFailed = false
                if detail.analyzed { analysis = detail }
            } catch {
                analysisReadFailed = true
                if (error as? HTTPError)?.isAuthFailure == true { break }
            }
        }
        guard let analysis else {
            debriefStatus[rideID] = .failed(analysisReadFailed
                ? String(localized: "The Intervals.icu analysis could not be read. Check your connection and try again.")
                : String(localized: "Intervals.icu hasn't finished analyzing this ride. Try again shortly."))
            return
        }
        // Re-read before writing: the review sheet may have saved RPE/legs while we waited.
        guard isSignedIn, athleteID == ride.athleteID else { debriefStatus[rideID] = nil; return }
        ride = self.ride(id: rideID) ?? ride
        ride.analysis = analysis
        rideCache[rideID] = ride
        try? store.save(ride, at: "rides/\(rideID.uuidString).json")

        if ride.sourceActivity != nil, ride.recordedRoute == nil {
            await loadRideRoute(rideID)
            guard isSignedIn, athleteID == ride.athleteID else { debriefStatus[rideID] = nil; return }
            ride = self.ride(id: rideID) ?? ride
        }

        guard let coach = await coachEngine() else {
            debriefStatus[rideID] = .failed(String(localized: "Connect ChatGPT (or an API key) in Settings → Coach first."))
            return
        }
        debriefStatus[rideID] = .reading
        let day = Day(ride.startedAt)
        let brief = RideDebrief.Brief(
            locale: coachLocale,
            ride: ride,
            ftp: ride.ftpUsed ?? workingFTP ?? 200,
            readiness: (state.today?.day == day) ? state.today?.readiness : nil,
            plan: state.plan,
            recentActivities: state.activities,
            analysis: analysis
        )
        do {
            var report = try await coach.debrief(brief)
            guard isSignedIn, athleteID == ride.athleteID, var latest = self.ride(id: rideID) else { debriefStatus[rideID] = nil; return }
            if refreshing {
                report.correctionNotice = String(localized: "Updated analysis from Intervals.icu results. This replaces the earlier assessment.")
                latest.debriefNote = nil
            }
            latest.debrief = report
            try store.save(latest, at: "rides/\(rideID.uuidString).json")
            rideCache[rideID] = latest
            debriefStatus[rideID] = nil
            await syncDebriefNote(for: rideID)
        } catch let error as LLMCoachError {
            switch error {
            case .usageLimitReached: coachIssue = .usageLimit
            case .notEligible: coachIssue = .notEligible
            case .unauthorized: coachIssue = .signInAgain
            }
            debriefStatus[rideID] = .failed(String(localized: "The coach could not be reached. Check the coach connection in Settings and try again."))
        } catch is CancellationError {
            debriefStatus[rideID] = nil
        } catch let error as LLMCoach.CompletionError {
            debriefStatus[rideID] = .failed(coachFailureNotice(error, preservingSession: false))
        } catch {
            debriefStatus[rideID] = .failed(coachFailureNotice(error, preservingSession: false))
        }
    }

    // MARK: Settings

    func updateSettings(_ body: (inout AppState.Settings) -> Void) {
        mutate { body(&$0.settings) }
    }

    func setLLMKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { keychain.delete(Self.llmKeyAccount) } else { keychain.write(trimmed, account: Self.llmKeyAccount) }
        mutate { $0.settings.llmEnabled = !trimmed.isEmpty }
        Task { await askCoachForToday() }
    }

    func clearSyncError() { syncError = nil }

    /// Preview/testing hook: replace state wholesale.
    func load(_ state: AppState) { self.state = state }
}
