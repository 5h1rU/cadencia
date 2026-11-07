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
    /// The coach's latest consultation reply beyond the question the backend records: the review, suggested
    /// answers, a proposed profile edit and the draft's details. Kept for this launch only.
    private(set) var consultationReply: (id: CadenciaAPI.ConsultationId, reply: PlanConsultation.Reply)?
    /// The Cadencia sign-in (Keychain). The plan and the coach's memory live on the backend.
    private(set) var backendSession: BackendSession?
    /// Why the last call to Cadencia's backend failed, for Settings and the plan screens.
    private(set) var backendError: String?
    @ObservationIgnored private var flushingOutbox = false
    @ObservationIgnored private var flushRequested = false
    private(set) var isUploading = false
    /// Rides whose finish is still running: file, index and upload entry, Apple Health, the first upload.
    private(set) var finishingRides: Set<UUID> = []
    /// Rides written to Apple Health this launch, so the review confirms a save only once it happened.
    private(set) var healthSavedRides: Set<UUID> = []

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
    /// Rides whose Intervals note is being synced right now (automatically or from a Retry tap).
    private(set) var syncingDebriefNotes: Set<UUID> = []
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
    private let persistence: PersistenceQueue
    private let keychain: KeychainStore
    private let transport: any HTTPTransport
    private let coachOverride: LLMCoach?
    /// Previews use their own backend; the app signs in to `AppConfig.backendURL`.
    private let backendOverride: CoachBackend?
    /// Observed on purpose: debrief, note and route updates reach the screens through this cache.
    /// Never evicted per entry; `releaseCachedRides()` and account changes clear it (except unsaved rides).
    private var rideCache: [UUID: RideRecording] = [:]
    /// Ride ids with a `saveRide` write still on its way to disk. Their cache entries survive purges, or a
    /// reload could read the older file and a later save would drop the newer change.
    @ObservationIgnored private var rideWritesInFlight: [UUID: Int] = [:]
    /// Rides whose newest cached copy failed to reach disk (the last `saveRide` threw). The cache is their
    /// only copy, so purges keep them, and the outdoor import saves them again. An outdoor import built from
    /// nothing is not kept: the next sync rebuilds it from Intervals.
    @ObservationIgnored private var unsavedRides: Set<UUID> = []
    /// Bumped by every purge, so an off-main read that overlapped one reads again instead of caching an older file.
    @ObservationIgnored private var rideCachePurges = 0
    /// Rides older than the debrief window whose Intervals note is still pending; nil until probed this launch.
    @ObservationIgnored private var pendingOlderNoteIDs: Set<UUID>?
    @ObservationIgnored private var olderNotesRetry: Task<Void, Never>?
    private var isMirroring = false
    private var calendarWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var syncTaskAccount: String?
    /// The credential the running sync was started with; a sign-in with a new one does not join it.
    @ObservationIgnored private var syncTaskCredential: IntervalsCredential?
    @ObservationIgnored private var followUpTask: Task<Void, Never>?
    /// The athlete whose sync follow-ups were requested while a pass was running; runs once that pass ends.
    @ObservationIgnored private var followUpRequest: String?
    /// A daily ask that was dropped while the coach was busy, or whose answer was discarded because the
    /// brief changed. Replayed once when the coach is free; the fingerprint check stops repeat LLM calls.
    /// A sign-out or an account switch drops it.
    @ObservationIgnored private var coachAskPending = false
    @ObservationIgnored private var coachAskForced = false
    /// `coachBrief().fingerprint` for the current state and day. Cleared on every state change; filled on
    /// first use, which can be inside a view body, hence ignored by observation.
    @ObservationIgnored private var briefFingerprintCache: (day: Day, value: CadenciaAPI.Fingerprint)?

    private static let stateFile = "state.json"
    private static let credentialAccount = "intervals.credential"
    private static let llmKeyAccount = "llm.apiKey"
    private static let chatGPTAccount = "chatgpt.credential"
    private static let chatGPTClientIDAccount = "chatgpt.clientID"
    private static let chatGPTHostIDAccount = "chatgpt.hostID"
    private static let backendSessionAccount = "cadencia.session"

    init(state: AppState, credential: IntervalsCredential?, store: JSONStore, keychain: KeychainStore,
         transport: any HTTPTransport, bluetooth: BluetoothManager = BluetoothManager(), health: HealthKitService = HealthKitService(),
         coachOverride: LLMCoach? = nil, backendOverride: CoachBackend? = nil) {
        self.state = state
        self.credential = credential
        self.store = store
        self.persistence = PersistenceQueue(store: store, statePath: Self.stateFile)
        self.keychain = keychain
        self.transport = transport
        self.coachOverride = coachOverride
        self.backendOverride = backendOverride
        self.bluetooth = bluetooth
        self.health = health
        self.chatGPT = keychain.readCodable(ChatGPTCredential.self, account: Self.chatGPTAccount)
        self.hasLLMKey = keychain.readString(Self.llmKeyAccount)?.isEmpty == false
        self.backendSession = keychain.readCodable(BackendSession.self, account: Self.backendSessionAccount)
        // Never DispatchQueue.main.sync here: flush() runs on the main thread and would deadlock.
        persistence.onError = { [weak self] message in
            Task { @MainActor [weak self] in self?.syncError = message }
        }
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
        // A ride only completes its own day's session; one day of slack covers rides around midnight.
        // Filtering the index first keeps view bodies from decoding every saved ride.
        let from = session.day.adding(days: -1).date(), to = session.day.adding(days: 2).date()
        return state.rideIndex
            .filter { $0.startedAt >= from && $0.startedAt < to }
            .sorted { $0.startedAt > $1.startedAt }
            .first {
                guard let ride = ride(id: $0.id), ride.athleteID == athleteID else { return false }
                return ride.completes(session)
            }
    }

    var completedRideToday: AppState.RideIndexEntry? {
        let today = self.today
        if state.today?.day == today, let id = state.today?.completedRideID,
           let entry = state.rideIndex.first(where: { $0.id == id }) { return entry }
        if let session = state.session(on: today), let entry = completedRide(for: session) { return entry }
        let start = today.date(), end = today.adding(days: 1).date(), workoutID = todayWorkout?.id
        return state.rideIndex
            .filter { $0.startedAt >= start && $0.startedAt < end }
            .sorted { $0.startedAt > $1.startedAt }
            .first {
                guard let ride = ride(id: $0.id), ride.athleteID == athleteID else { return false }
                return ride.endedAt != nil && ride.workout.id == workoutID
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
        guard let t = state.today, t.day == today, let note = t.note, !note.isEmpty else { return nil }
        return note
    }

    /// The coming seven days of the plan, today first, as Home lists them. Days the plan leaves free are rest.
    var weekOutlook: [DailyPrescription.DayOutlook] {
        guard let plan = state.plan, plan.isActive else { return [] }
        return (0..<7).compactMap { offset -> DailyPrescription.DayOutlook? in
            let day = today.adding(days: offset)
            guard day >= plan.startDay, day <= plan.endDay else { return nil }
            if offset == 0, let workout = todayWorkout {
                return .init(day: day, kind: workout.kind, minutes: Int((workout.totalDuration / 60).rounded()), title: workout.name,
                             note: coachNote?.session)
            }
            guard let session = plan.sessions.first(where: { $0.day == day && $0.status != .skipped }) else {
                return .init(day: day, kind: .rest, minutes: 0, title: SessionKind.rest.defaultTitle)
            }
            return .init(day: day, kind: session.kind, minutes: session.targetMinutes, title: session.title, note: session.note)
        }
    }

    /// The plan's answer to today's decision, when the backend has one.
    var todayDecision: CadenciaAPI.TodayDecisionState? {
        guard let decision = state.todayDecision?.value, decision.day == CadenciaAPI.Day(today) else { return nil }
        return decision
    }

    var pendingUploads: [UploadEntry] { state.ledger.pending(for: athleteID) }

    /// Whether `runUploads(force: true)` has something to send: signed in, with pending or uncertain
    /// uploads, backoff ignored. Parked (needs reconnect) and confirmed entries never count.
    var canRetryUploads: Bool { isSignedIn && !state.ledger.retryable(for: athleteID).isEmpty }

    /// Cached so view bodies never query the Keychain; setLLMKey(_:) is the only writer of the key.
    private(set) var hasLLMKey = false

    var client: IntervalsClient? {
        credential.map { IntervalsClient(transport: transport, credential: $0, athleteID: athleteID) }
    }

    /// Cadencia's backend for the signed-in athlete. Nil once its session has expired (it lasts 30 days):
    /// until the athlete signs in again, rides and Intervals.icu keep working but the plan and the coach wait.
    var backend: CoachBackend? {
        if let backendOverride { return backendOverride }
        guard let session = backendSession, isSignedIn, session.athleteID == state.athlete?.id,
              let athlete = CadenciaAPI.AthleteId(rawValue: session.athleteID) else { return nil }
        return CoachBackend(api: CadenciaAPI(baseURL: AppConfig.backendURL, transport: transport, sessionToken: session.token), athleteId: athlete)
    }

    /// Whether the plan and the coach can be used: they need a live Cadencia session.
    var isBackendConnected: Bool { backend != nil }

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
        // The Keychain is read only when a key exists and the endpoint has a speech URL.
        guard hasOpenAISpeech, let key = keychain.readString(Self.llmKeyAccount), !key.isEmpty else { return nil }
        return RideCommentator.OpenAISpeech(transport: transport, endpoint: state.settings.llmEndpoint, apiKey: key, voice: state.settings.coachVoice)
    }

    /// Whether the ride coach can use OpenAI's voice. For views: never touches the Keychain.
    var hasOpenAISpeech: Bool { hasLLMKey && CoachVoice.speechURL(nextTo: state.settings.llmEndpoint) != nil }

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
        mutate {
            $0.plan?.event?.course?.route = upgraded
            if $0.planContext?.event?.course?.route?.id == route.id { $0.planContext?.event?.course?.route = upgraded }
        }
    }

    /// Hands the writer an O(1) copy-on-write snapshot; nothing is encoded on the main actor. Snapshots
    /// coalesce, so a burst of mutations costs one write. Failures surface through `syncError`.
    private func persist() {
        persistence.submit(state)
    }

    /// The only writer of `state` besides `load(_:)`.
    private func mutate(_ body: (inout AppState) -> Void) {
        var next = state
        body(&next)
        // A no-op neither writes nor invalidates the views that read `state`.
        guard next != state else { return }
        state = next
        briefFingerprintCache = nil
        persist()
    }

    /// Blocks until every queued write, including the newest state, is on disk. For app backgrounding
    /// and account changes, where a lost write would matter.
    func flushPersistence() {
        persistence.flush()
    }

    /// Waits, without blocking the main thread, until every write queued so far is on disk.
    func settlePersistence() async {
        await persistence.settle()
    }

    // MARK: Account

    enum SignInError: LocalizedError {
        /// Signing in again with a different Intervals.icu account than this phone's.
        case otherAthlete

        var errorDescription: String? {
            String(localized: "Sign in to Cadencia with the same Intervals.icu account the app uses.")
        }
    }

    /// Signs in through Cadencia's backend, which sends the athlete to Intervals.icu: it gives the session
    /// for the plan and the coach, and the athlete's Intervals.icu token for the calls this phone makes to
    /// Intervals itself (ride uploads, wellness, settings, calendar entries, notes, streams). On a phone that is
    /// already signed in it replaces both, for the same athlete: after the session expired, or after
    /// Intervals stopped accepting the token.
    func signIn() async throws {
        let (session, credential) = try await BackendSignIn().signIn(transport: transport)
        if isSignedIn, session.athleteID != state.athlete?.id { throw SignInError.otherAthlete }
        let athlete = try await IntervalsClient(transport: transport, credential: credential).athlete()
        backendSession = session
        keychain.writeCodable(session, account: Self.backendSessionAccount)
        backendError = nil
        setCredential(credential, athlete: athlete)
        await refresh()
    }

    private func setCredential(_ credential: IntervalsCredential, athlete: AthleteProfile) {
        cyclistProfileError = nil
        self.credential = credential
        keychain.writeCodable(credential, account: Self.credentialAccount)
        if state.athlete?.id != athlete.id {
            // The previous athlete's rides must not answer this one's lookups.
            purgeRideCache()
            pendingOlderNoteIDs = nil
            // Nor may their queued daily ask run for this athlete; this athlete's sync asks for itself.
            coachAskPending = false
            coachAskForced = false
        }
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
        // Durable at once: a lost account reset would graft the new athlete onto the old athlete's data.
        flushPersistence()
        syncError = nil
    }

    /// Signs out. Rides that have not reached Intervals stay on disk, parked under this athlete's id,
    /// and resume when the same athlete signs back in.
    func signOut() async {
        backendSession = nil
        keychain.delete(Self.backendSessionAccount)
        backendError = nil
        consultationReply = nil
        credential = nil
        cyclistProfileError = nil
        keychain.delete(Self.credentialAccount)
        bluetooth.disconnectAll()
        purgeRideCache()
        pendingOlderNoteIDs = nil
        coachAskPending = false
        coachAskForced = false
        mutate {
            $0.wellness = []
            $0.activities = []
            $0.calendarEvents = nil
            $0.powerCurve = []
            $0.today = nil
            $0.lastSyncAt = nil
            $0.plan = nil
            $0.planContext = nil
            $0.coachThread = nil
            $0.todayDecision = nil
            $0.riderProfile = nil
            $0.consultation = nil
        }
        flushPersistence()
    }

    // MARK: Cadencia backend

    /// Turns a backend failure into something the athlete can act on. An expired session signs out.
    private func backendFailure(_ error: Error) -> String {
        let message: String
        switch error as? CadenciaAPIError {
        case .signedOut?:
            backendSession = nil
            keychain.delete(Self.backendSessionAccount)
            message = String(localized: "Your Cadencia sign-in expired. Sign in again in Settings.")
        case .transport?:
            message = String(localized: "Cadencia couldn't be reached. Check your connection and try again.")
        case .rejected(tag: "SessionNotMovable", _, _)?:
            // The athlete took the session over in Intervals.icu, or it was skipped: the plan no longer moves it.
            message = String(localized: "This session can't be moved any more: it was changed in Intervals.icu or skipped.")
        case .rejected(tag: "IntentExpired", _, _)?:
            message = String(localized: "The days this change was for have passed, so your plan can't apply it.")
        case .rejected(tag: "ImplausibleToday", _, _)?:
            message = String(localized: "Your device's date doesn't match today's. Check the date and time in your device settings.")
        case .rejected(let tag, _, _)?:
            message = String(localized: "Cadencia refused the change (\(tag)).")
        case nil where error is CadenciaAPI.InvalidValue:
            // Checked before sending: what the coach wrote, or what was typed, is outside what Cadencia keeps.
            message = String(localized: "Cadencia can't keep this as written (\(String(describing: error))). Try again.")
        default:
            message = String(localized: "Cadencia is unavailable right now. Try again later.")
        }
        backendError = message
        return message
    }

    /// Reads the backend's views into the caches: the plan, today's decision, this month's conversation, the
    /// rider profile and an open consultation. Each read is independent; the first failure is reported.
    func refreshBackend() async {
        guard let backend else { return }
        let account = athleteID, day = today
        func current() -> Bool { backend.athleteId.rawValue == athleteID && athleteID == account && isSignedIn }
        do {
            let plan = try await backend.plan()
            guard current() else { return }
            mutate { $0.adoptBackendPlan(plan) }
            let decision = try await backend.decision(on: day)
            guard current() else { return }
            adoptDecision(decision, day: day)
            let thread = try await backend.thread(on: day)
            guard current() else { return }
            mutate { $0.coachThread = .init(thread) }
            let profile = try await backend.profile()
            guard current() else { return }
            mutate { $0.riderProfile = .init(profile) }
            if let open = state.consultation {
                let view = try await backend.consultation(open.id)
                guard current() else { return }
                mutate { $0.consultation?.view = .init(view) }
            }
            backendError = nil
        } catch is CancellationError {
            return
        } catch {
            if current() { _ = backendFailure(error) }
        }
    }

    /// Takes the plan's answer to `day`'s decision: an accepted workout becomes the one to ride, unless it is
    /// already today's (same evidence) or the ride is done.
    private func adoptDecision(_ decision: CadenciaAPI.TodayDecisionState?, day: Day) {
        mutate { $0.todayDecision = .init(decision) }
        guard let decision, decision.status == .accepted, decision.day == CadenciaAPI.Day(day), let wire = decision.workout,
              let fingerprint = decision.evidence?.fingerprint.rawValue,
              state.today?.day != day || state.today?.aiFingerprint != fingerprint else { return }
        let measured = measuredToday()
        let readiness = decision.evidence.map {
            Readiness(level: Readiness.Level(rawValue: $0.readiness.level.rawValue) ?? measured.level, score: $0.readiness.score.rawValue,
                      signals: measured.signals, missingData: measured.missingData, summary: $0.readiness.summary.rawValue)
        } ?? measured
        let workout = Workout(wire, identity: "\(athleteID):\(day.iso)#\(decision.attempt?.rawValue ?? 0)")
        mutate {
            $0.takeDecision(workout: workout, readiness: readiness, note: decision.note.map(CoachNote.init), model: decision.model?.rawValue,
                            day: day, ftp: workingFTP)
            $0.today?.aiFingerprint = fingerprint
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

    /// Forgets the tokens, then revokes them at OpenAI. Registration ids stay so re-signing in is a reauthorization.
    func signOutChatGPT() async {
        guard let credential = chatGPT else { return }
        // Local state first, so Settings updates at once; the revoke is best-effort and can stall.
        chatGPT = nil
        keychain.delete(Self.chatGPTAccount)
        if coachIssue != nil { coachIssue = nil }
        try? await ChatGPTAuth().revoke(credential, transport: transport)
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
                // Signed out (or into another account) meanwhile: never write the old account back.
                guard self.chatGPT == current else { return self.chatGPT }
                self.setChatGPT(next)
                return next
            } catch ChatGPTAuth.Failure.refreshTokenUnusable {
                if self.chatGPT == current { self.coachIssue = .signInAgain }
                return nil
            } catch {
                guard self.chatGPT == current else { return self.chatGPT }
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

    /// Syncs with Intervals and Health and returns once that data is in (`isSyncing` covers exactly this).
    /// The follow-ups (weight sync, retired events, the coach, uploads, the calendar mirror, the debrief
    /// scan) continue in a model-owned task that no caller awaits; `coachThinking` and `isUploading` show them.
    /// A call during a sync for the same athlete and credential waits for that sync instead of returning at
    /// once; after a sign-in with a new credential it waits and then syncs again. The sync itself is
    /// unstructured, so a cancelled caller (a popped `.refreshable`) never cancels it.
    func refresh() async {
        while let running = syncTask {
            // A re-sign-in of the same athlete must not settle for a sync that reads with the old credential.
            let sameSync = syncTaskAccount == athleteID && syncTaskCredential == credential
            await running.value
            if sameSync { return }
        }
        guard client != nil else { return }
        let account = athleteID
        let sync = Task {
            // The data phase may adopt the fetched athlete when none was stored, so follow-ups use its answer.
            let followUpAccount = await syncData(account: account)
            syncTask = nil
            syncTaskAccount = nil
            syncTaskCredential = nil
            if let followUpAccount { scheduleFollowUps(account: followUpAccount) }
        }
        syncTask = sync
        syncTaskAccount = account
        syncTaskCredential = credential
        await sync.value
    }

    /// The data phase of a sync. Returns the athlete the follow-ups may run for, or nil when the account
    /// changed (a sign-out or a switch) during the pass.
    private func syncData(account: String) async -> String? {
        var account = account
        guard let client else { return nil }
        isSyncing = true
        defer { isSyncing = false }
        // Before the first read: reading back replaces the caches, so local-only data must be queued first.
        migrateToIntervalsIfNeeded()
        dropLocalPlan()

        // Each fetch is independent: a failing request (for example a malformed power-curve query)
        // must not discard the athlete, wellness, and activities that did arrive. The first failure
        // is surfaced; an auth failure wins over everything else because the user has to act on it.
        var failures: [(String, Error)] = []

        do {
            let athlete = try await client.athlete()
            guard isSignedIn, athleteID == account else { return nil }
            // A kept credential with no stored athlete (state.json gone, Keychain kept after a reinstall):
            // the placeholder id becomes this athlete's, or every account check below would end the first sync.
            if state.athlete == nil {
                account = athlete.id
                syncTaskAccount = athlete.id
            }
            mutate { $0.adoptIntervalsAthlete(athlete) }
        } catch { failures.append(("athlete", error)) }
        // Signed out or switched while a request failed: report and stamp nothing for the old account.
        guard isSignedIn, athleteID == account else { return nil }

        if (failures.first?.1 as? HTTPError)?.isAuthFailure == true {
            syncError = String(localized: "Intervals.icu no longer accepts Cadencia. Sign in again in Settings.")
        } else {
            do {
                let range = today.adding(days: -90)...today
                let wellness = try await client.wellness(oldest: range.lowerBound, newest: range.upperBound)
                guard isSignedIn, athleteID == account else { return nil }
                mutate { $0.adoptIntervalsWellness(wellness, range: range) }
            } catch { failures.append(("wellness", error)) }

            do {
                let activities = try await client.activities(oldest: today.adding(days: -42), newest: today)
                guard isSignedIn, athleteID == account else { return nil }
                mutate {
                    $0.activities = activities
                    $0.adoptIntervalsCompletion(activities)
                }
                try await importOutdoorRides(activities)
            } catch { failures.append(("activities", error)) }

            do {
                let curve = try await client.powerCurve(newest: today)
                guard isSignedIn, athleteID == account else { return nil }
                mutate { $0.powerCurve = curve }
            } catch { failures.append(("power curve", error)) }

            do {
                let window = today...today.adding(days: 42)
                let events = try await client.events(oldest: window.lowerBound, newest: window.upperBound)
                guard isSignedIn, athleteID == account else { return nil }
                let day = today
                mutate {
                    $0.calendarEvents = events
                    $0.adoptIntervalsCalendar(events, window: window, today: day)
                }
            } catch { failures.append(("calendar", error)) }

            guard isSignedIn, athleteID == account else { return nil }
            if failures.count < 5 {
                mutate { $0.lastSyncAt = Date() }
            }
            syncError = failures.first.map { "Intervals \($0.0): \($0.1.localizedDescription)" }
        }

        // After the import above, so a paired outdoor ride already holds its planned-route snapshot.
        if isSignedIn, athleteID == account { pruneCompletedRoutePlans() }
        await readHealth()
        // Reads only activities and the power curve, so it may run before the follow-ups.
        recomputeFTPEstimate()
        return isSignedIn && athleteID == account ? account : nil
    }

    /// Runs a sync's slow follow-ups in one model-owned task. A request that arrives while a pass runs
    /// queues one more pass (for the newest athlete) instead of a parallel one.
    private func scheduleFollowUps(account: String) {
        followUpRequest = account
        guard followUpTask == nil else { return }
        followUpTask = Task {
            while let account = followUpRequest {
                followUpRequest = nil
                await runFollowUps(account: account)
            }
            followUpTask = nil
        }
    }

    /// Today's order, with the same athlete re-checked before every step.
    private func runFollowUps(account: String) async {
        func current() -> Bool { isSignedIn && athleteID == account }
        guard current() else { return }
        await flushIntervalsOutbox()
        guard current() else { return }
        await retireCalendarEvents()
        guard current() else { return }
        // The plan's sessions reach the Intervals calendar from the backend (`CalendarPublishing`).
        await refreshBackend()
        guard current() else { return }
        await askCoachForToday()
        guard current() else { return }
        await runUploads()
        guard current() else { return }
        await mirrorCalendarEntries()
        guard current() else { return }
        await debriefRecentRides()
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
            if state.settings.pushWellnessToIntervals, isSignedIn, let todayHealth = days.first(where: { $0.day == today }) {
                mutate { $0.enqueue(WellnessUpdate(health: todayHealth)) }
                await flushIntervalsOutbox()
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
    private func coachBrief() -> CoachBrief {
        let state = self.state
        let available = state.plan?.availability.minutesByWeekday[today.weekday()]
        let requestedLimit = state.workoutRequest(on: today)?.maxMinutes
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
        brief.workoutRequest = state.workoutRequest(on: today)
        brief.ftpReviewWatts = ftpProposal
        brief.plannedRoutes = calendarSessions.filter { $0.route != nil && $0.day >= today && $0.day <= today.adding(days: 7) }.map(CoachBrief.PlannedRow.init)
        return brief
    }

    private var feedbackIndex: [Day: SubjectiveFeedback] {
        Dictionary(uniqueKeysWithValues: state.feedbackByDay.values.map { ($0.day, $0) })
    }

    private var coachLocale: String { Locale.current.language.languageCode?.identifier ?? "es" }

    /// `coachBrief().fingerprint`, built at most once per state change and day. Every brief input derives
    /// from `state` and `today`, and `mutate`/`load` clear the cache whenever `state` changes.
    private var currentBriefFingerprint: CadenciaAPI.Fingerprint {
        let day = today
        if let cached = briefFingerprintCache, cached.day == day { return cached.value }
        let value = coachBrief().fingerprint
        briefFingerprintCache = (day, value)
        return value
    }

    /// Today's measured signals even before the coach has answered (the Recovery row shows them).
    var measuredSignals: Readiness { measuredToday() }

    /// Asks the coach again from synchronous call sites (feedback, FTP change, plan change).
    private func reaskCoach() {
        Task { await askCoachForToday() }
    }

    /// Asks the language model for today's decision when the inputs changed since the last answer
    /// (or always, with `force`). With an active plan the decision is recorded on the backend and the plan
    /// decides: an accepted workout is today's; a refused one goes back to the model with the plan's reason,
    /// at most twice. On a day without a plan there is nothing to decide against, and the coach's workout is
    /// today's as it is. Plan problems become `coachIssue`. Returns true when today has a new workout.
    ///
    /// A call while the coach is busy (a decision or a chat reply) is queued and replayed once it ends, as is
    /// a call whose answer was discarded because the inputs changed meanwhile. A sign-out or an account
    /// switch drops what is queued: the next account's sync asks for itself. Nothing else replays, and the
    /// fingerprint check still skips the LLM when nothing changed, so replays cannot loop.
    @discardableResult
    func askCoachForToday(force: Bool = false) async -> Bool {
        if coachThinking || coachBusy {
            coachAskPending = true
            coachAskForced = coachAskForced || force
            return false
        }
        guard !isTodayWorkoutCompleted else { return false }
        guard let ftp = workingFTP, ftp > 0 else {
            coachNotice = String(localized: "Add FTP in your cyclist profile to generate power-based workouts.")
            return false
        }
        let day = today, account = athleteID, signedIn = isSignedIn
        let brief = coachBrief()
        let basis = brief.fingerprint
        if !force, let current = state.today, current.day == day, current.aiFingerprint == basis.rawValue {
            coachNotice = nil
            return false
        }
        // The plan already refused this very evidence twice; asking again only spends the athlete's plan.
        if !force, let decision = todayDecision, decision.status == .refused, decision.evidence?.fingerprint == basis {
            return false
        }
        let planned = state.plan.flatMap { plan -> (id: CadenciaAPI.PlanId, session: Bool)? in
            guard plan.isActive, let id = plan.backendID, day >= plan.startDay, day <= plan.endDay else { return nil }
            return (id, plan.sessions.contains { $0.day == day && $0.status != .skipped })
        }
        if planned != nil, backend == nil {
            coachNotice = String(localized: "Sign in to Cadencia in Settings so your plan can confirm today's session.")
            return false
        }

        // Claim the request before token refresh can suspend and let another caller enter.
        coachThinking = true
        coachNotice = nil
        defer {
            coachThinking = false
            replayCoachAskIfNeeded()
        }
        guard let engine = await coachEngine() else {
            coachNotice = coachSource == nil ? nil : String(localized: "ChatGPT no longer accepts this sign-in. Sign in again in Settings → Coach.")
            return false
        }
        func stillCurrent() -> Bool { today == day && !isTodayWorkoutCompleted && athleteID == account && isSignedIn == signedIn }
        /// The inputs changed while the coach was writing (an FTP accepted, Health merged, a plan saved): the
        /// answer describes an older brief, so ask once more when this call ends.
        func briefChanged() -> Bool {
            guard currentBriefFingerprint != basis else { return false }
            if athleteID == account, isSignedIn == signedIn {
                coachAskPending = true
                coachAskForced = coachAskForced || force
            }
            return true
        }
        do {
            let prescriptionFTP = workingFTP
            var prescription = try await engine.prescribe(brief: brief)
            try Task.checkCancellation()
            guard stillCurrent(), !briefChanged() else { return false }
            // A rest on a day the plan leaves free needs no verdict.
            guard let planned, let backend, planned.session || prescription.workout.kind != .rest else {
                mutate { s in
                    s.takeDecision(workout: prescription.workout, readiness: prescription.readiness, note: prescription.note,
                                   model: prescription.model, day: day, ftp: prescriptionFTP)
                    s.today?.aiFingerprint = basis.rawValue
                }
                return true
            }
            let evidence = try CoachEvidence.snapshot(fingerprint: basis, readiness: prescription.readiness,
                                                  availability: state.athlete?.trainingAvailability,
                                                  events: state.calendarEvents ?? [], from: day)
            for attempt in 1...3 {
                let verdict: CadenciaAPI.TodayDecisionState
                do {
                    verdict = try await backend.recordDecision(on: day, planId: planned.id, workout: prescription.workout,
                                                               note: prescription.note, evidence: evidence, model: prescription.model)
                } catch CadenciaAPIError.rejected(tag: "DecisionAlreadyAccepted", _, _) {
                    // This evidence already has an accepted workout (another ask got there first): take it.
                    verdict = try await backend.decision(on: day) ?? CadenciaAPI.TodayDecisionState(status: .none, awaiting: [])
                }
                guard stillCurrent(), backend.athleteId.rawValue == athleteID else { return false }
                switch verdict.status {
                case .accepted:
                    adoptDecision(verdict, day: day)
                    if state.today?.aiFingerprint != basis.rawValue {
                        // The view had no workout (an older backend): the coach's own is the accepted one.
                        mutate { s in
                            s.takeDecision(workout: prescription.workout, readiness: prescription.readiness, note: prescription.note,
                                           model: prescription.model, day: day, ftp: prescriptionFTP)
                            s.today?.aiFingerprint = basis.rawValue
                        }
                    }
                    if let plan = try? await backend.plan(), backend.athleteId.rawValue == athleteID { mutate { $0.adoptBackendPlan(plan) } }
                    coachNotice = nil
                    return true
                case .refused where attempt < 3:
                    mutate { $0.todayDecision = .init(verdict) }
                    prescription = try await engine.prescribe(brief: brief, refusal: verdict.refusal?.explanation ?? "The plan refused the session.")
                    try Task.checkCancellation()
                    guard stillCurrent(), !briefChanged() else { return false }
                case .refused:
                    mutate { $0.todayDecision = .init(verdict) }
                    coachNotice = String(localized: "Your plan didn't accept the coach's session for today. Ask again later or tell the coach what changed.")
                    return false
                case .pending, .none:
                    mutate { $0.todayDecision = .init(verdict) }
                    coachNotice = String(localized: "Your plan hasn't confirmed today's session yet. Pull to refresh in a moment.")
                    return false
                }
            }
            return false
        } catch is CancellationError {
            return false
        } catch let error as LLMCoachError {
            switch error {
            case .usageLimitReached: coachIssue = .usageLimit
            case .notEligible: coachIssue = .notEligible
            case .unauthorized: coachIssue = .signInAgain
            }
        } catch let error as DailyPrescription.ValidationError {
            coachNotice = String(localized: "The coach's answer failed a safety check (\(String(describing: error))). Ask again.")
        } catch let error as CadenciaAPIError {
            coachNotice = backendFailure(error)
        } catch let error as CadenciaAPI.InvalidValue {
            coachNotice = backendFailure(error)
        } catch let error as LLMCoach.CompletionError {
            coachNotice = coachFailureNotice(error)
        } catch {
            coachNotice = coachFailureNotice(error)
        }
        return false
    }

    /// Runs the daily ask that was queued while the coach was busy, once neither a decision nor a chat
    /// reply is in flight. Called from the defers of `askCoachForToday` and `sendToCoach`.
    private func replayCoachAskIfNeeded() {
        guard coachAskPending, !coachThinking, !coachBusy else { return }
        let force = coachAskForced
        coachAskPending = false
        coachAskForced = false
        // A queued ask belongs to the account that queued it; after a sign-out the next sync asks for itself.
        guard isSignedIn else { return }
        Task { await askCoachForToday(force: force) }
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

    func recordFeeling(_ legs: SubjectiveFeedback.Legs?, motivation: Int? = nil) {
        var fb = state.feedback(for: today) ?? SubjectiveFeedback(day: today)
        fb.legs = legs
        if let motivation { fb.motivation = motivation }
        mutate { $0.setFeedback(fb) }
        Task { await flushIntervalsOutbox() }
        reaskCoach()
    }

    // MARK: FTP

    private func recomputeFTPEstimate() {
        let since = today.adding(days: -42)
        let efforts = state.activities.filter { $0.isCycling && $0.day >= since && $0.movingTime >= 12 * 60 && ($0.intensity ?? 0) >= 85 }.count
        let eftp = FTPEstimator.intervalsEFTP(activities: state.activities, wellness: state.wellness, today: today)
        let estimate = FTPEstimator().estimate(curve: state.powerCurve, sustainedEfforts: efforts, intervalsEFTP: eftp)
        mutate { $0.ftpEstimate = estimate }
    }

    /// Queues the FTP for Intervals' Ride settings; it is the working FTP until Intervals confirms it.
    func acceptFTP(_ watts: Int) {
        mutate { $0.acceptedFTP = watts; $0.dismissedFTPProposal = nil }
        Task { await flushIntervalsOutbox() }
        reaskCoach()
    }

    func keepCurrentFTP() {
        mutate { $0.dismissedFTPProposal = ftpProposal }
    }

    /// Drops an accepted FTP that has not reached Intervals yet, so the Intervals value is the working FTP again.
    func useIntervalsFTP() {
        mutate { $0.acceptedFTP = nil; $0.dismissedFTPProposal = nil }
        reaskCoach()
    }

    // MARK: Plan

    /// The open consultation as the screens show it: the turns the backend recorded, and the coach's latest
    /// reply from this launch (its review, suggested answers and draft details).
    var planConsultation: PlanConsultation.Session? {
        guard let open = state.consultation else { return nil }
        var session = PlanConsultation.Session(startedOn: open.startedOn)
        session.id = StableID.uuid(open.id.rawValue)
        session.messages = (open.view.value?.turns ?? []).enumerated().map { index, turn in
            var message = PlanConsultation.Message(role: turn.role == .coach ? .coach : .athlete, text: turn.text.rawValue)
            message.id = StableID.uuid("\(open.id)#\(index)")
            return message
        }
        if let reply = consultationReply, reply.id == open.id {
            session.reply = reply.reply
            // A draft the athlete has answered since is not one to accept.
            if session.messages.last?.role == .athlete { session.reply?.draft = nil }
        }
        return session
    }

    func beginPlanConsultation() async {
        // Today's consultation, or one the athlete has answered, continues. An opening question nobody answered
        // was written for the day (and plan) it was asked on, so another day starts fresh. Not reset on every
        // call: the consultation screen calls this after every pop.
        let keep = planConsultation.map { session in
            session.startedOn >= today || session.messages.contains { $0.role == .athlete }
        } ?? false
        if !keep {
            guard await startConsultation() else { return }
        }
        let session = planConsultation
        guard session?.reply == nil || session?.messages.last?.role == .athlete else { return }
        await requestPlanConsultation()
    }

    func restartPlanConsultation() async {
        consultationRequestID = nil
        consultationBusy = false
        consultationError = nil
        guard await startConsultation() else { return }
        await requestPlanConsultation()
    }

    /// Opens a new consultation on the backend.
    private func startConsultation() async -> Bool {
        guard let backend else {
            consultationError = String(localized: "Sign in to Cadencia in Settings to create a plan.")
            return false
        }
        do {
            let id = try await backend.startConsultation()
            consultationReply = nil
            mutate { $0.consultation = .init(id: id, startedOn: today, view: .init(nil)) }
            return true
        } catch {
            consultationError = backendFailure(error)
            return false
        }
    }

    func cancelPlanConsultationRequest() {
        consultationRequestID = nil
        consultationBusy = false
    }

    func sendPlanConsultationAnswer(_ text: String) async {
        let answer = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty, answer.count <= 6000, !consultationBusy, let open = state.consultation, let backend else { return }
        consultationBusy = true
        defer { consultationBusy = false }
        do {
            let view = try await backend.answer(answer, in: open.id)
            guard state.consultation?.id == open.id else { return }
            mutate { $0.consultation?.view = .init(view) }
        } catch {
            consultationError = backendFailure(error)
            return
        }
        consultationBusy = false
        await requestPlanConsultation()
    }

    /// Asks the coach for its next consultation turn and records it: the question, and the draft when there is one.
    func requestPlanConsultation() async {
        guard !consultationBusy, let open = state.consultation, let session = planConsultation else { return }
        guard let backend else {
            consultationError = String(localized: "Sign in to Cadencia in Settings to create a plan.")
            return
        }
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
            consultationRequestID == requestID && state.consultation?.id == open.id
        }
        guard let engine = await coachEngine() else {
            // Without a coach the screen already asks to connect one, and connecting it starts the consultation
            // there; an error here would outlive the connection. A connected coach that could not be resolved
            // (its ChatGPT token could not be refreshed) is a connection problem.
            if isCurrent(), aiCoachAvailable {
                consultationError = String(localized: "The coach could not be reached. Check the coach connection in Settings and try again.")
            }
            return
        }
        do {
            let reply = try await engine.consult(context)
            guard isCurrent() else { return }
            var view = try await backend.recordQuestion(reply.question, model: engine.model, in: open.id)
            if let draft = reply.draft {
                view = try await backend.recordDraft(try CadenciaAPI.PlanDraft(draft, today: day),
                                                     model: engine.model, in: open.id)
            }
            guard isCurrent() else { return }
            consultationReply = (open.id, reply)
            mutate { $0.consultation?.view = .init(view) }
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
        } catch let error as CadenciaAPIError {
            if isCurrent() { consultationError = backendFailure(error) }
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
            if let kg = update.weightKg { $0.enqueue(WellnessUpdate(day: today, weightKg: kg)) }
            if let cm = update.heightCm { $0.updateOutbox { $0.heightCm = cm } }
            if let ftp = update.ftp { $0.acceptedFTP = ftp; $0.dismissedFTPProposal = nil }
        }
        consultationReply?.reply.profileUpdate = nil
        // Saved locally above. The Intervals writes do not hold up Save; a failure stays queued in the
        // outbox and the next sync retries it.
        Task { await flushIntervalsOutbox() }
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
        let previous = state.cyclistMeasurements
        mutate {
            $0.cyclistMeasurements = current
            // An explicit import is the athlete's new measurement: Intervals gets it too.
            if let w = current.weight, w != previous?.weight { $0.enqueue(WellnessUpdate(day: Day(w.measuredAt), weightKg: w.value)) }
            if let h = current.height, h != previous?.height { $0.updateOutbox { $0.heightCm = h.value } }
        }
        Task { await flushIntervalsOutbox() }
        return true
    }

    /// Queues, once, what older versions kept only on this phone (see `IntervalsMigration`).
    private func migrateToIntervalsIfNeeded() {
        guard isSignedIn, (state.intervalsMigrationVersion ?? 0) < IntervalsMigration.version else { return }
        mutate { s in
            let pendingWeight = s.profileWeightPendingSync.map { WellnessUpdate(day: $0.day, weightKg: $0.kg) }
            s.intervalsOutbox = IntervalsMigration.outbox(feedback: Array(s.feedbackByDay.values), wellness: s.wellness,
                measurements: s.cyclistMeasurements, athlete: s.athlete, unitsMetric: s.settings.unitsMetric,
                availability: s.planAvailability, pendingWeight: pendingWeight, existing: s.intervalsOutbox ?? .init())
            if s.intervalsOutbox?.isEmpty == true { s.intervalsOutbox = nil }
            s.profileWeightPendingSync = nil
            // Legacy queued deletions by server id join the external-id queue.
            let legacy = (s.retiredPlanEventIDs ?? []).map { CalendarSync.Deletion(externalID: nil, eventID: $0) }
            if !legacy.isEmpty { s.retiredCalendarEvents = (s.retiredCalendarEvents ?? []) + legacy }
            s.retiredPlanEventIDs = nil
            if var plan = s.plan { CalendarSync.pinIdentifiers(in: &plan); s.plan = plan }
            s.intervalsMigrationVersion = IntervalsMigration.version
        }
    }

    /// The plan now lives on the backend. A plan this phone built on its own is not carried over (the athlete
    /// creates it again with the consultation); its upcoming planned rides leave the Intervals calendar.
    private func dropLocalPlan() {
        // A day decided before the backend kept no note or model: ask the coach again.
        if state.today?.model == nil, state.today?.aiFingerprint != nil { mutate { $0.today?.aiFingerprint = nil } }
        guard let plan = state.plan, plan.backendID == nil else { return }
        let deletions = plan.sessions.filter { $0.day >= today && $0.status != .completed }
            .map { CalendarSync.Deletion(externalID: PlanMirror.externalID(for: $0.day), eventID: $0.intervalsEventID) }
        mutate {
            $0.retiredCalendarEvents = ($0.retiredCalendarEvents ?? []) + deletions
            $0.plan = nil
            $0.planContext = nil
        }
    }

    /// Sends the outbox and drops what Intervals confirmed. One flush runs at a time; a call during a flush
    /// makes it go round once more for what was queued meanwhile.
    func flushIntervalsOutbox() async {
        if flushingOutbox { flushRequested = true; return }
        flushingOutbox = true
        defer { flushingOutbox = false }
        repeat {
            flushRequested = false
            await flushOutboxOnce()
        } while flushRequested
    }

    private func flushOutboxOnce() async {
        guard let client, isSignedIn, state.intervalsOutbox != nil || state.acceptedFTP != nil else { return }
        let account = athleteID
        let outbox = state.intervalsOutbox ?? IntervalsOutbox()
        let result = await client.flush(outbox, ftp: state.acceptedFTP, athlete: state.athlete, today: today)
        guard account == athleteID, isSignedIn else { return }
        mutate { s in
            s.updateOutbox { $0.removeConfirmed(result) }
            if let ftp = result.ftp, s.acceptedFTP == ftp {
                if let athlete = s.athlete { s.athlete = IntervalsAthleteFields.applying(ftp: ftp, to: athlete) }
                s.acceptedFTP = nil
            }
            if let cm = result.heightCm, var athlete = s.athlete { athlete.heightCm = cm; s.athlete = athlete }
            if let preference = result.measurementPreference, var athlete = s.athlete { athlete.measurementPreference = preference; s.athlete = athlete }
            if let days = result.availability, var athlete = s.athlete { athlete.trainingAvailability = days; s.athlete = athlete }
        }
        if let failure = result.failure { syncError = failure }
    }

    enum PlanCreationError: LocalizedError {
        case refused(String), notConfirmed
        var errorDescription: String? {
            switch self {
            case .refused: return String(localized: "Your plan couldn't be created from this draft. Go back and ask the coach to revise it.")
            case .notConfirmed: return String(localized: "Cadencia hasn't confirmed the new plan yet. Check the Plan tab in a moment.")
            }
        }
    }

    #if DEBUG
    /// A coach reply for a preview's open consultation.
    func previewConsultationReply(_ reply: PlanConsultation.Reply) {
        if let id = state.consultation?.id { consultationReply = (id, reply) }
    }
    #endif

    /// Explicit acceptance is the only place a consultation can replace an active plan. The backend creates the
    /// plan from the recorded draft, retires the previous one and publishes its sessions; this phone writes what
    /// Intervals holds natively (availability, time away, other training, the goal event).
    func activateConsultationPlan(_ draft: PlanConsultation.Draft, sessionID: UUID) async throws {
        guard isSignedIn, !consultationBusy, !Task.isCancelled, let open = state.consultation, StableID.uuid(open.id.rawValue) == sessionID,
              planConsultation?.reply?.draft == draft else { throw PlanConsultation.ValidationError.invalidDraft }
        let preview = try draft.makePlan(today: today)
        try await acceptDraft(in: open.id, context: { planId in
            PlanContext(planId: planId, availability: preview.availability, details: draft.details, event: preview.event)
        })
    }

    /// Accepts the consultation's draft as a new plan and adopts it once Planning created it.
    private func acceptDraft(in consultation: CadenciaAPI.ConsultationId, context: (CadenciaAPI.PlanId) -> PlanContext) async throws {
        guard let backend else { throw CadenciaAPIError.signedOut }
        let planId = BackendID.newPlan(athlete: backend.athleteId)
        let completedToday = isTodayWorkoutCompleted
        let answer: CadenciaAPI.ConsultationViewState?
        do { answer = try await backend.acceptDraft(planId: planId, in: consultation) } catch {
            _ = backendFailure(error)
            throw error
        }
        switch answer?.stage {
        case .created?: break
        case .open?: throw PlanCreationError.refused(answer?.refusal?.explanation ?? "")
        default: throw PlanCreationError.notConfirmed
        }
        var newContext = context(planId)
        if var event = newContext.event, event.externalID == nil { event.externalID = CalendarEntry.race(event).externalID; newContext.event = event }
        if var details = newContext.details {
            for i in details.timeAway.indices where details.timeAway[i].externalID == nil {
                details.timeAway[i].externalID = CalendarEntry.timeAway(details.timeAway[i])?.externalID
            }
            newContext.details = details
        }
        let plan = try? await backend.plan(showing: planId)
        mutate {
            $0.planContext = newContext
            $0.adoptBackendPlan(plan)
            if !completedToday { $0.today = nil; $0.todayDecision = nil }
            $0.consultation = nil
            if let availability = $0.planAvailability { $0.updateOutbox { $0.availability = availability } }
        }
        consultationReply = nil
        // The plan is active and the backend retires the previous one itself; the calendar and the coach follow
        // in a model-owned task, so the review screen can close now and nothing is lost if the caller goes away.
        Task {
            await flushIntervalsOutbox()
            await askCoachForToday()
            await mirrorCalendarEntries()
        }
    }

    /// Deletes the planned rides of replaced or discarded plans: by day external id (every copy this app
    /// created) and by server id when known (events earlier builds created with an API key, legacy ids). A day that has a planned ride
    /// again keeps its event. Retried by every sync until it succeeds.
    private func retireCalendarEvents() async {
        guard state.retiredCalendarEvents?.isEmpty == false else { return }
        await acquireCalendar()
        defer { releaseCalendar() }
        guard let client, !Task.isCancelled else { return }
        let account = athleteID
        let queued = state.retiredCalendarEvents ?? []
        let sessions = calendarSessions
        let rideDays = Set(sessions.map { PlanMirror.externalID(for: $0.day) })
        let keptIDs = Set(sessions.compactMap(\.intervalsEventID))
        let deletions = queued.compactMap { d -> CalendarSync.Deletion? in
            let externalID = d.externalID.flatMap { rideDays.contains($0) ? nil : $0 }
            let eventID = d.eventID.flatMap { keptIDs.contains($0) ? nil : $0 }
            return externalID == nil && eventID == nil ? nil : .init(externalID: externalID, eventID: eventID)
        }
        do { try await client.deleteEvents(deletions) } catch { return }
        guard account == athleteID, isSignedIn else { return }
        mutate { s in
            s.retiredCalendarEvents?.removeAll { queued.contains($0) }
            if s.retiredCalendarEvents?.isEmpty == true { s.retiredCalendarEvents = nil }
        }
    }

    /// Brings the plan's goal event, time away and other training on the Intervals calendar in line with the
    /// plan, without overwriting what the athlete changed there (see `CalendarSync`).
    func mirrorCalendarEntries() async {
        await acquireCalendar()
        defer { releaseCalendar() }
        guard let client, isSignedIn, !Task.isCancelled else { return }
        let account = athleteID, day = today
        if var plan = state.plan {
            CalendarSync.pinIdentifiers(in: &plan)
            mutate { $0.plan = plan }
        }
        let desired = CalendarEntry.entries(for: state.plan, today: day)
        let base = state.calendarEntryBase ?? [:]
        guard !desired.isEmpty || !base.isEmpty else { return }
        do {
            let next = try await client.syncCalendarEntries(desired, base: base, today: day)
            guard account == athleteID, isSignedIn else { return }
            mutate { $0.calendarEntryBase = next.isEmpty ? nil : next }
        } catch {
            syncError = "Intervals calendar: \(error.localizedDescription)"
        }
    }

    /// A plan for an event from the event flow: Cadencia's own template, not the AI's, recorded as the draft of
    /// a consultation (with `PlanBuilder.templateModel` as its author) so Planning creates it like any other.
    func createPlan(_ request: PlanBuilder.Request) async throws {
        guard let backend else { throw CadenciaAPIError.signedOut }
        let template = PlanBuilder().build(request)
        let consultation: CadenciaAPI.ConsultationId
        do {
            let objective = request.event?.objective.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let rationale = template.phases.map(\.summary).joined(separator: " ")
            let draft = try CadenciaAPI.PlanDraft(template,
                                                  objective: objective.isEmpty ? template.title : objective,
                                                  rationale: rationale.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? template.title : rationale)
            consultation = try await backend.startConsultation()
            _ = try await backend.recordDraft(draft, model: PlanBuilder.templateModel, in: consultation)
        } catch {
            _ = backendFailure(error)
            throw error
        }
        // A consultation the athlete never answered (opened, then left for the event flow) ends with it,
        // so a later Create a plan starts fresh instead of reopening that old question.
        if planConsultation?.messages.contains(where: { $0.role == .athlete }) != true {
            mutate { $0.consultation = nil }
        }
        try await acceptDraft(in: consultation) { planId in
            PlanContext(planId: planId, availability: request.availability, event: request.event)
        }
    }

    /// Retires the plan on the backend, which withdraws its upcoming sessions from the Intervals calendar.
    /// Its other calendar entries follow from the empty plan; the athlete's weekly availability stays in
    /// Intervals. The coach is asked again without the caller waiting for it.
    func discardPlan() async {
        guard let planId = state.plan?.backendID, let backend else { return }
        do {
            let view = try await backend.retirePlan(planId, today: today)
            mutate { $0.adoptBackendPlan(view) }
        } catch CadenciaAPIError.rejected(tag: "PlanNotActive", _, _) {
            mutate { $0.adoptBackendPlan(nil) }
        } catch {
            _ = backendFailure(error)
            return
        }
        mutate {
            // An unanswered consultation's opening was written about this plan; the next Create a plan starts fresh.
            if $0.consultation?.view.value?.turns.contains(where: { $0.role == .athlete }) != true { $0.consultation = nil }
        }
        await mirrorCalendarEntries()
        reaskCoach()
    }

    /// Moves one of the plan's sessions to another day. Planning decides whether the day can take it.
    func moveSession(_ session: PlannedSession, to day: Day) async throws {
        guard let backend, let planId = state.plan?.backendID,
              let sessionId = state.plan?.sessions.first(where: { $0.id == session.id })?.backendID else { return }
        do {
            let view = try await backend.moveSession(sessionId, to: day, plan: planId)
            mutate { $0.adoptBackendPlan(view) }
        } catch {
            _ = backendFailure(error)
            throw error
        }
        if session.day == today || day == today { reaskCoach() }
    }

    /// Accepts the change a coach reply proposes. Planning applies it to the week (or refuses it); what the
    /// athlete asked of each day becomes that day's requirement, in their own words.
    func acceptCoachProposal(messageID: CadenciaAPI.MessageId) async {
        guard let backend, !coachBusy, let thread = state.coachThread?.value,
              let index = thread.messages.firstIndex(where: { $0.messageId == messageID }),
              let intent = thread.messages[index].intent, thread.messages[index].intentStatus == .proposed else { return }
        let conversation = BackendID.conversation(athlete: backend.athleteId, day: dayOfThread(thread) ?? today)
        coachBusy = true
        defer {
            coachBusy = false
            replayCoachAskIfNeeded()
        }
        do {
            let answered = try await backend.acceptIntent(messageId: messageID, in: conversation, today: today)
            mutate { $0.coachThread = .init(answered) }
            let source = thread.messages[..<index].last { $0.role == .athlete }?.text.rawValue ?? intent.summary.rawValue
            if answered?.messages.first(where: { $0.messageId == messageID })?.intentStatus == .applied {
                for limit in intent.limits where !limit.unavailable {
                    guard let day = Day(limit.day), day >= today else { continue }
                    _ = try await backend.recordDayRequirement(source, maxMinutes: limit.maxMinutes?.rawValue, on: day, plan: intent.planId)
                }
            }
            if let plan = try await backend.plan() { mutate { $0.adoptBackendPlan(plan) } }
            coachNotice = nil
        } catch {
            coachNotice = backendFailure(error)
            return
        }
        coachBusy = false
        if intent.limits.contains(where: { $0.day == CadenciaAPI.Day(today) }) { await askCoachForToday(force: true) }
    }

    func dismissCoachProposal(messageID: CadenciaAPI.MessageId) async {
        guard let backend, let thread = state.coachThread?.value else { return }
        let conversation = BackendID.conversation(athlete: backend.athleteId, day: dayOfThread(thread) ?? today)
        do {
            let answered = try await backend.dismissIntent(messageId: messageID, in: conversation)
            mutate { $0.coachThread = .init(answered) }
        } catch {
            coachNotice = backendFailure(error)
        }
    }

    /// The month a cached thread belongs to, from its first message.
    private func dayOfThread(_ thread: CadenciaAPI.ConversationThreadState) -> Day? {
        thread.messages.first.flatMap { BackendDate.parse($0.at) }.map { Day($0) }
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
    }

    private func saveCalendarEvent(_ id: Int, session: PlannedSession, ftp: Int) {
        let written = PlanMirror.nativeFields(for: session, ftp: ftp)
        mutate { s in
            if let i = s.plan?.sessions.firstIndex(where: { $0.id == session.id }) {
                s.plan?.sessions[i].intervalsEventID = id
                s.plan?.sessions[i].mirrored = written
                if session.location == .outdoor {
                    s.plan?.sessions[i].deliveredWorkout = session.workout
                    s.plan?.sessions[i].deliveredFTP = ftp
                }
            }
            if let i = s.standaloneSessions?.firstIndex(where: { $0.id == session.id }) {
                s.standaloneSessions?[i].intervalsEventID = id
                s.standaloneSessions?[i].mirrored = written
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

    /// Starts the single automatic generation in a model-owned task, so leaving Home cannot cancel it after
    /// the attempt has been recorded. Home calls it (without awaiting) once both connections exist; repeat
    /// calls are no-ops while busy or once the attempt is spent.
    func startAutomaticCyclistProfile() {
        guard !cyclistProfileBusy,
              CyclistProfile.shouldGenerateAutomatically(hasReport: state.cyclistProfile != nil,
                                                         attemptedAt: state.cyclistProfileAutomaticAttemptedAt),
              client != nil, aiCoachAvailable, isBackendConnected else { return }
        Task { await generateCyclistProfile(automatically: true) }
    }

    /// The only automatic caller is `startAutomaticCyclistProfile()`, from the Home screen's first
    /// appearance with both connections. Sync, daily prescriptions, plan changes and model changes never
    /// regenerate this snapshot.
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
        guard let backend else {
            cyclistProfileError = String(localized: "Sign in to Cadencia in Settings to build your cyclist profile.")
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
            // Recorded before the AI runs, so an automatic attempt is spent even if this one fails.
            guard try await backend.recordProfileAttempt(automatic: automatically) else { return }
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
            let card = try await backend.recordProfile(report)
            guard sameAccount() else { return }
            mutate { $0.riderProfile = .init(card) }
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
        } catch let error as CadenciaAPIError {
            guard !Task.isCancelled, sameAccount() else { return }
            cyclistProfileError = backendFailure(error)
        } catch let error as HTTPError {
            // Intervals reports a cancelled request as a transport error; cancellation is not a failure.
            guard !Task.isCancelled, sameAccount() else { return }
            cyclistProfileError = error.isAuthFailure
                ? String(localized: "Intervals.icu no longer accepts Cadencia. Sign in again in Settings.")
                : String(localized: "Couldn't read your Intervals.icu history. Try generating your profile again.")
        } catch {
            guard !Task.isCancelled, sameAccount() else { return }
            cyclistProfileError = coachFailureNotice(error, preservingSession: false)
        }
    }

    /// Sends the athlete's message to the coach. The message and the coach's reply (with the plan change it
    /// understood, which takes effect only once the athlete accepts it) are recorded on the backend; the
    /// conversation shown is the backend's.
    func sendToCoach(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !coachBusy else { return }
        guard let backend else {
            coachNotice = String(localized: "Sign in to Cadencia in Settings to talk to the coach.")
            return
        }
        coachBusy = true
        coachNotice = nil
        defer {
            coachBusy = false
            replayCoachAskIfNeeded()
        }
        let account = athleteID, day = today, messageID = BackendID.newMessage()
        func current() -> Bool { athleteID == account && today == day && backend.athleteId.rawValue == athleteID }
        let recent = state.coachMessages.suffix(8).map { "\($0.role.rawValue): \($0.text.rawValue)" }
        do {
            let receipt = try await backend.sendMessage(trimmed, messageId: messageID, on: day)
            let sent = try await backend.thread(on: day, after: receipt)
            guard current() else { return }
            mutate { $0.coachThread = .init(sent) }
        } catch {
            coachNotice = backendFailure(error)
            return
        }
        // When the ChatGPT refresh token is dead `freshChatGPTCredential` sets `coachIssue = .signInAgain`;
        // the Coach screen shows that as a banner with a sign-in action.
        guard let engine = await coachEngine() else {
            coachNotice = String(localized: "Connect ChatGPT (or an API key) in Settings → Coach first.")
            return
        }
        let context = CoachContext(today: day, locale: coachLocale, readiness: readiness, plan: state.plan,
                                   recentActivities: Array(state.activities.suffix(10)), ftp: workingFTP,
                                   workout: todayWorkout, recentConversation: recent)
        do {
            let intent = try await engine.interpret(trimmed, context: context)
            guard current() else { return }
            let proposal = try state.plan.flatMap { plan -> CadenciaAPI.Intent? in
                guard plan.isActive, let id = plan.backendID else { return nil }
                return try CadenciaAPI.Intent(intent, planId: id, today: day)
            }
            let thread = try await backend.recordReply(intent.reply, messageId: BackendID.newMessage(), inReplyTo: messageID,
                                                       intent: proposal, model: engine.model, on: day)
            guard current() else { return }
            mutate { $0.coachThread = .init(thread) }
            if let request = intent.workoutRequest, proposal == nil, state.plan?.isActive != true {
                coachNotice = request.day == day
                    ? String(localized: "Without a plan the coach takes your request into today's session when it decides the day.")
                    : String(localized: "Create a plan so the coach can keep requests for other days.")
            }
        } catch let error as LLMCoachError {
            guard current() else { return }
            switch error {
            case .usageLimitReached:
                coachIssue = .usageLimit
                coachNotice = String(localized: "You've reached the usage limit of your ChatGPT plan for now. Check it under Manage usage, or wait for it to reset.")
            case .notEligible:
                coachIssue = .notEligible
                coachNotice = String(localized: "Your ChatGPT account can't share its plan with apps. You can use an API key instead in Settings → Coach.")
            case .unauthorized:
                coachIssue = .signInAgain
                coachNotice = String(localized: "ChatGPT no longer accepts this sign-in. Sign in again in Settings → Coach.")
            }
        } catch is CancellationError {
            return
        } catch let error as CadenciaAPIError {
            guard current() else { return }
            coachNotice = backendFailure(error)
        } catch {
            guard current() else { return }
            coachNotice = coachFailureNotice(error, preservingSession: false)
        }
    }

    /// Reads this month's conversation again (the Coach screen calls it when it appears).
    func refreshConversation() async {
        guard let backend else { return }
        let day = today
        do {
            let thread = try await backend.thread(on: day)
            if backend.athleteId.rawValue == athleteID { mutate { $0.coachThread = .init(thread) } }
        } catch {
            coachNotice = backendFailure(error)
        }
    }

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
        do {
            try Task.checkCancellation()
            guard athleteID == account, !state.isWorkoutCompleted(on: day), day >= today,
                  state.session(on: day)?.id == sessionID,
                  state.session(on: day).map({ $0.kind != .rest && $0.kind != .strength && $0.status != .skipped }) ?? true else { throw OutdoorError.changed }
        } catch {
            // Nothing refers to the file just written (route ids are fresh per import); do not leave it behind.
            store.remove(at: Self.routePath(route.id))
            throw error
        }
        let replaced = state.rideRoutePlans?[day.iso]?.route.id
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
        if let replaced, replaced != route.id { removeRouteSourceIfUnused(replaced) }
        Task { await askCoachForToday() }
    }

    func removeRideRoute(on day: Day) {
        guard !state.isWorkoutCompleted(on: day) else { return }
        let removed = state.rideRoutePlans?[day.iso]?.route.id
        mutate { state in
            state.rideRoutePlans?[day.iso] = nil
            if let i = state.plan?.sessions.firstIndex(where: { $0.day == day }) {
                state.plan?.sessions[i].route = nil; state.plan?.sessions[i].routeFileName = nil; state.plan?.sessions[i].routeSourceIndex = nil
            }
            if let i = state.standaloneSessions?.firstIndex(where: { $0.day == day }) {
                state.standaloneSessions?[i].route = nil; state.standaloneSessions?[i].routeFileName = nil; state.standaloneSessions?[i].routeSourceIndex = nil
            }
        }
        if let removed { removeRouteSourceIfUnused(removed) }
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

    private nonisolated static func routePath(_ id: UUID) -> String { "routes/\(id.uuidString).gpx" }

    /// Deletes a route's source GPX once nothing in the state refers to it. Queued behind the state write
    /// that dropped the last reference, so a crash cannot leave the saved state pointing at a deleted file.
    private func removeRouteSourceIfUnused(_ id: UUID) {
        let sessions = (state.plan?.sessions ?? []) + (state.standaloneSessions ?? [])
        guard state.rideRoutePlans?.values.contains(where: { $0.route.id == id }) != true,
              state.plan?.event?.course?.route?.id != id,
              !sessions.contains(where: { $0.route?.id == id }) else { return }
        let store = store, path = Self.routePath(id)
        persistence.enqueue { store.remove(at: path) }
    }

    /// Drops the planned routes of completed past days, which no screen shows any more: such a day opens
    /// its ride, which keeps its own snapshot (`RideRecording.plannedRoute`, taken when the paired outdoor
    /// ride was imported), and the coach and the calendar mirror read only today onward. Missed days keep theirs.
    private func pruneCompletedRoutePlans() {
        let today = self.today
        let stale = (state.rideRoutePlans ?? [:]).filter { key, _ in
            Day(iso: key).map { $0 < today && state.isWorkoutCompleted(on: $0) } ?? false
        }
        guard !stale.isEmpty else { return }
        mutate { s in for key in stale.keys { s.rideRoutePlans?[key] = nil } }
        for plan in stale.values { removeRouteSourceIfUnused(plan.route.id) }
    }

    /// Fetch actual GPS automatically on review, cache locally, and keep failures independent of AI notes.
    func loadRideRoute(_ rideID: UUID, retry: Bool = false) async {
        guard let ride = await loadRide(id: rideID), ride.athleteID == athleteID, ride.sourceActivity != nil,
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
            try await saveRide(latest)
            rideRouteStatus[rideID] = nil
        } catch is CancellationError {
            rideRouteStatus[rideID] = nil
        } catch {
            // Intervals reports a cancelled request as a transport error; leaving the screen is not a failure.
            guard !Task.isCancelled, athleteID == account else { rideRouteStatus[rideID] = nil; return }
            rideRouteStatus[rideID] = .failed(String(localized: "The recorded GPS route is not available from Intervals.icu. Retry after the activity finishes syncing, or import its recorded GPX."))
        }
    }

    func attachRecordedRoute(_ route: GPXRoute, to rideID: UUID) throws {
        guard var ride = ride(id: rideID), ride.athleteID == athleteID else { throw OutdoorError.changed }
        ride.recordedRoute = route; ride.recordedRouteCheckedAt = Date()
        // Synchronous because it throws to its caller, but still behind any queued write of this ride,
        // so an older copy can never land after it.
        let store = store, path = Self.ridePath(rideID), saved = ride
        try persistence.writeNow { try store.save(saved, at: path) }
        rideCache[rideID] = ride; rideRouteStatus[rideID] = nil
        unsavedRides.remove(rideID)
    }

    /// Head-unit rides are already in Intervals. Save a local review record without ever enqueuing
    /// an upload or writing another Health workout. Stable ids make repeated refreshes idempotent.
    /// Previous recordings are read off the main actor, and unchanged, indexed ones are not cached.
    private func importOutdoorRides(_ activities: [ActivitySummary]) async throws {
        let account = athleteID
        let candidates = activities.filter { activity in
            activity.externalID?.hasPrefix("cadencia-") != true &&
                !state.ledger.entries.contains(where: { $0.intervalsActivityID == activity.id })
        }
        let ids = candidates.map { OutdoorRideImport.recordingID(athleteID: account, activityID: $0.id) }
        let (stored, unreadable) = await readRideFiles(ids)
        guard isSignedIn, athleteID == account else { return }
        let purges = rideCachePurges
        let sessions = calendarSessions
        for (activity, id) in zip(candidates, ids) {
            // A purge would hide a ride that was cached instead of read above; the next sync imports the rest.
            guard rideCachePurges == purges else { return }
            // The cache holds the newest in-app edit; otherwise the file read above is current.
            let previous = rideCache[id] ?? stored[id]
            // A saved ride whose file could not be read (a locked device cannot open `.completeFileProtection`
            // files) must not be rebuilt from nothing over its debrief, notes and routes; the next sync imports it.
            if previous == nil, unreadable.contains(id) { continue }
            guard let ride = OutdoorRideImport.recording(activity: activity, sessions: sessions, athleteID: account,
                fallbackFTP: outdoorFTP ?? 200, existing: previous) else { continue }
            // An unchanged import is done once it is indexed, unless its last save failed: then file and index
            // are still missing. A sign-out or a crash between the file write and the index leaves it unindexed.
            if previous == ride, !unsavedRides.contains(id), state.rideIndex.contains(where: { $0.id == id }) { continue }
            // The file is on disk before the index entry that points at it.
            do {
                try await saveRide(ride)
            } catch {
                // A ride built from nothing is cached only once its file is on disk; kept as unsaved, the stub
                // would be saved again later, even over a file the next sync could have read.
                if previous == nil, rideCache[id] == ride, rideWritesInFlight[id] == nil {
                    rideCache[id] = nil
                    unsavedRides.remove(id)
                }
                throw error
            }
            guard isSignedIn, athleteID == account else { return }
            mutate { s in
                let entry = AppState.RideIndexEntry(id: id, name: activity.name, kind: ride.workout.kind, startedAt: activity.startDateLocal,
                    duration: activity.movingTime, averageWatts: activity.averageWatts, load: activity.trainingLoad)
                if let i = s.rideIndex.firstIndex(where: { $0.id == id }) { s.rideIndex[i] = entry } else { s.rideIndex.append(entry) }
                s.completeSession(for: ride)
            }
        }
    }

    private nonisolated static func ridePath(_ id: UUID) -> String { "rides/\(id.uuidString).json" }

    /// Loads synchronously on a cache miss. View bodies should prefer `cachedRide(id:)` plus a
    /// `loadRide(id:)` task. Model code uses it for the few rides of one day (the completion checks)
    /// and to re-read a ride it has already loaded, where a miss only follows a purge.
    func ride(id: UUID) -> RideRecording? {
        if let r = rideCache[id] { return r }
        let r = store.load(RideRecording.self, at: Self.ridePath(id))
        if let r { rideCache[id] = r }
        return r
    }

    /// The ride if it is already in memory. Never touches the disk, so view bodies can call it freely.
    func cachedRide(id: UUID) -> RideRecording? { rideCache[id] }

    /// Loads a ride into the cache off the main actor and returns it; nil when it has no readable file.
    /// Returns at once when the ride is cached.
    @discardableResult
    func loadRide(id: UUID) async -> RideRecording? {
        let store = store, path = Self.ridePath(id)
        while true {
            if let cached = rideCache[id] { return cached }
            let purges = rideCachePurges
            let loaded = await Task.detached(priority: .userInitiated) { store.load(RideRecording.self, at: path) }.value
            // A save made meanwhile is in the cache, and it is newer than the file just read.
            if let cached = rideCache[id] { return cached }
            // A purge meanwhile may have dropped a save that landed after this read: read again.
            guard purges == rideCachePurges else { continue }
            if let loaded { rideCache[id] = loaded }
            return loaded
        }
    }

    /// Caches the recent rides that view bodies look up synchronously (Home's completion check, the Plan's
    /// current and previous weeks), reading them off the main actor in one pass, so those screens open
    /// without decoding ride files on the main thread. Called once at launch.
    func warmRecentRides() async {
        let from = today.adding(days: -15).date(), to = today.adding(days: 2).date()
        let ids = state.rideIndex.filter { $0.startedAt >= from && $0.startedAt < to }.map(\.id)
        let loaded = await readRideFiles(ids).rides
        guard !loaded.isEmpty else { return }
        // One cache write, so open screens re-render once. A save made during the read is newer and wins.
        var cache = rideCache
        for (id, ride) in loaded where cache[id] == nil { cache[id] = ride }
        rideCache = cache
    }

    /// Reads the files of the given rides that are not cached, off the main actor and without caching them.
    /// Reads again if the cache was purged meanwhile, so the cache plus the result holds each ride's newest copy.
    /// `unreadable` holds the rides whose file exists but could not be read, as while the device is locked;
    /// a ride missing from both has no file, or one that does not decode.
    private func readRideFiles(_ ids: [UUID]) async -> (rides: [UUID: RideRecording], unreadable: Set<UUID>) {
        let store = store
        while true {
            let missing = ids.filter { rideCache[$0] == nil }.map { ($0, Self.ridePath($0)) }
            guard !missing.isEmpty else { return ([:], []) }
            let purges = rideCachePurges
            // The sync's data phase (and so its spinner) waits for this read.
            let read = await Task.detached(priority: .userInitiated) { () -> (rides: [UUID: RideRecording], unreadable: Set<UUID>) in
                var rides: [UUID: RideRecording] = [:]
                var unreadable: Set<UUID> = []
                for (id, path) in missing {
                    do { rides[id] = try store.loadIfPresent(RideRecording.self, at: path) } catch { unreadable.insert(id) }
                }
                return (rides, unreadable)
            }.value
            if purges == rideCachePurges { return read }
        }
    }

    /// Caches the ride at once, then writes its file on the persistence queue, off the main actor.
    /// Every caller reads the latest cached ride and calls this with no suspension in between, so the
    /// queue's FIFO order matches the cache's order and the newest copy always lands last.
    private func saveRide(_ ride: RideRecording) async throws {
        let id = ride.id
        rideCache[id] = ride
        rideWritesInFlight[id, default: 0] += 1
        defer {
            if let count = rideWritesInFlight[id], count > 1 { rideWritesInFlight[id] = count - 1 }
            else { rideWritesInFlight[id] = nil }
        }
        let store = store, path = Self.ridePath(id)
        // Writes of one ride finish in FIFO order, so the last outcome describes the newest copy.
        do {
            try await persistence.write { try store.save(ride, at: path) }
            unsavedRides.remove(id)
        } catch {
            unsavedRides.insert(id)
            throw error
        }
    }

    /// Frees the cached rides on a memory warning; they reload from disk on demand. Rides with a write
    /// still in flight, or whose newest copy failed to reach disk, stay cached.
    func releaseCachedRides() {
        purgeRideCache()
    }

    private func purgeRideCache() {
        let kept = rideCache.filter { rideWritesInFlight[$0.key] != nil || unsavedRides.contains($0.key) }
        guard kept.count != rideCache.count else { return }
        rideCache = kept
        rideCachePurges += 1
    }

    func finishRide(_ recording: RideRecording) async {
        guard recording.sourceActivity == nil else { return }
        finishingRides.insert(recording.id)
        // The writes below finish after this returns to the main actor; pocketing the phone must not cut them short.
        let background = BackgroundActivity("Save ride")
        defer {
            finishingRides.remove(recording.id)
            background.end()
        }
        // The file goes first: the upload entry below must never point at a ride that is not on disk.
        do { try await saveRide(recording) } catch { syncError = error.localizedDescription }
        let ftp = workingFTP ?? 200
        mutate {
            if !$0.rideIndex.contains(where: { $0.id == recording.id }) {
                $0.rideIndex.append(.init(id: recording.id, name: recording.workout.name, kind: recording.workout.kind, startedAt: recording.startedAt,
                                      duration: recording.duration, averageWatts: recording.averageWatts, load: recording.trainingLoad(ftp: ftp)))
            }
            $0.ledger.enqueue(rideID: recording.id, athleteID: recording.athleteID)
            $0.completeSession(for: recording)
        }
        // The index and the upload entry are on disk before Health and the network see the ride.
        await settlePersistence()
        if state.settings.writeWorkoutsToHealth, (try? await health.saveWorkout(recording, ftp: ftp)) != nil {
            healthSavedRides.insert(recording.id)
        }
        await runUploads()
    }

    /// Saves RPE and legs locally and returns; the Intervals feedback sync continues on its own.
    func submitReview(rideID: UUID, rpe: Int?, legs: SubjectiveFeedback.Legs?) async {
        await loadRide(id: rideID)
        guard var ride = cachedRide(id: rideID) else { return }
        var fb = state.feedback(for: Day(ride.startedAt)) ?? SubjectiveFeedback(day: Day(ride.startedAt))
        fb.rpe = rpe
        fb.legs = legs
        ride.feedback = fb
        try? await saveRide(ride)
        mutate { $0.setFeedback(fb) }
        Task {
            await syncFeedback(for: rideID)
            await flushIntervalsOutbox()
        }
    }

    private func syncFeedback(for rideID: UUID) async {
        guard let client, let entry = state.ledger.entry(for: rideID), entry.state == .confirmed, !entry.feedbackSynced,
              let activityID = entry.intervalsActivityID, let fb = ride(id: rideID)?.feedback else { return }
        let feel: Int? = fb.legs.map { $0 == .fresh ? 1 : ($0 == .ok ? 3 : 5) }
        if (try? await client.updateActivityFeedback(activityID: activityID, rpe: fb.rpe, feel: feel)) != nil {
            mutate { $0.ledger.markFeedbackSynced(rideID) }
        }
    }

    /// Uploads the rides whose backoff has passed. `force` is the explicit Retry: it also sends pending and
    /// uncertain entries still in backoff (never parked or confirmed ones). Either way every upload first
    /// reconciles by `externalID`, so a retry cannot duplicate a ride.
    func runUploads(force: Bool = false) async {
        guard let client, !isUploading else { return }
        isUploading = true
        defer { isUploading = false }
        let now = Date()
        let entries = force ? state.ledger.retryable(for: athleteID) : state.ledger.due(for: athleteID, now: now)
        for entry in entries {
            guard let ride = await loadRide(id: entry.rideID), ride.sourceActivity == nil else { continue }
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
    /// the upload only went through on a later refresh). Loads only the rides inside the debrief window,
    /// off the main actor; pending Notes of older rides are retried by `retryOlderDebriefNotes(before:)`.
    private func debriefRecentRides() async {
        let cutoff = today.adding(days: -3).date()
        let account = athleteID
        for entry in state.rideIndex where entry.startedAt >= cutoff {
            let loaded = await loadRide(id: entry.id)
            guard isSignedIn, athleteID == account else { return }
            guard let ride = loaded, ride.athleteID == account,
                  state.ledger.entry(for: entry.id)?.state == .confirmed || ride.sourceActivity != nil else { continue }
            if RideDebrief.requiresRefresh(ride) {
                Task { await debriefRide(entry.id) }
            } else if ride.debrief != nil, ride.debriefNote == nil {
                Task { await syncDebriefNote(for: entry.id) }
            } else if (ride.sourceActivity == nil || ride.plannedSessionID != nil), debriefStatus[entry.id] == nil, ride.debrief == nil, ride.debriefNote == nil {
                Task { await debriefRide(entry.id) }
            }
        }
        retryOlderDebriefNotes(before: cutoff)
    }

    /// Retries pending Notes even when the original session is older than the debrief window, as every
    /// sync did before, without decoding every ride on the main actor: the ride files are probed once per
    /// launch off it, and `syncDebriefNote` keeps the pending set current after that.
    private func retryOlderDebriefNotes(before cutoff: Date) {
        guard olderNotesRetry == nil, client != nil else { return }
        let account = athleteID, store = store
        let older = Set(state.rideIndex.filter { $0.startedAt < cutoff }.map(\.id))
        guard !older.isEmpty else { return }
        let paths = older.map { ($0, Self.ridePath($0)) }
        olderNotesRetry = Task {
            defer { olderNotesRetry = nil }
            if pendingOlderNoteIDs == nil {
                let found = await Task.detached(priority: .utility) { () -> Set<UUID> in
                    Set(paths.compactMap { id, path in
                        guard let probe = store.load(PendingNoteProbe.self, at: path),
                              probe.athleteID == account, probe.notePending else { return nil }
                        return id
                    })
                }.value
                guard isSignedIn, athleteID == account else { return }
                pendingOlderNoteIDs = (pendingOlderNoteIDs ?? []).union(found)
            }
            for id in (pendingOlderNoteIDs ?? []).intersection(older) {
                guard isSignedIn, athleteID == account else { return }
                // Loaded off the main actor first, so the sync below finds it cached.
                if let ride = await loadRide(id: id), ride.debriefNote != nil {
                    pendingOlderNoteIDs?.remove(id)
                    continue
                }
                await syncDebriefNote(for: id)
            }
        }
    }

    /// Read Notes back for details, or save a pending local debrief. A saved report never needs
    /// another AI request just because its Intervals write failed or the app was closed.
    func syncDebriefNote(for rideID: UUID) async {
        guard let ride = await loadRide(id: rideID), !syncingDebriefNotes.contains(rideID), let client,
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
            // A revisit of an already synced ride changes nothing, so it writes nothing.
            if latest.debriefNote != note {
                latest.debriefNote = note
                try await saveRide(latest)
            }
            debriefNoteErrors[rideID] = nil
            pendingOlderNoteIDs?.remove(rideID)
        } catch {
            // Intervals reports a cancelled request as a transport error; leaving the screen is not a failure.
            guard !Task.isCancelled, isSignedIn, athleteID == ride.athleteID else { return }
            if ride.debrief != nil { pendingOlderNoteIDs?.insert(rideID) }
            if (error as? HTTPError)?.isAuthFailure == true {
                debriefNoteErrors[rideID] = String(localized: "Intervals.icu no longer accepts Cadencia. Sign in again in Settings. Your saved debrief is still available.")
            } else {
                debriefNoteErrors[rideID] = String(localized: "The coach note could not sync with Intervals. Your saved debrief is still available. Try again when connected.")
            }
        }
    }

    /// Asks the coach for the session's debrief: waits for Intervals to finish processing the upload,
    /// fetches its analysis, then hands the recording and that analysis to the coach. The answer is kept
    /// on the ride file; failures are kept in `debriefStatus` so the screen can offer a retry.
    func debriefRide(_ rideID: UUID) async {
        guard var ride = await loadRide(id: rideID), let client, ride.athleteID == athleteID else { return }
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
            if attempt > 0 {
                // Cancelled (the screen went away): stop quietly; the next open starts again.
                do { try await Task.sleep(for: .seconds(3)) } catch { debriefStatus[rideID] = nil; return }
            }
            attempt += 1
            do {
                let detail = try await client.activityDetail(id: activityID)
                analysisReadFailed = false
                if detail.analyzed { analysis = detail }
            } catch {
                // Intervals reports a cancelled request as a transport error, not as a failed read.
                if Task.isCancelled { debriefStatus[rideID] = nil; return }
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
        try? await saveRide(ride)

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
            try await saveRide(latest)
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

    /// Units live in Intervals (`measurement_preference`); the rest are this device's settings.
    func updateSettings(_ body: (inout AppState.Settings) -> Void) {
        let wasMetric = state.settings.unitsMetric
        mutate { s in
            body(&s.settings)
            if s.settings.unitsMetric != wasMetric {
                let preference = IntervalsAthleteFields.measurementPreference(metric: s.settings.unitsMetric)
                s.updateOutbox { $0.measurementPreference = preference }
            }
        }
        if state.settings.unitsMetric != wasMetric { Task { await flushIntervalsOutbox() } }
    }

    func setLLMKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { keychain.delete(Self.llmKeyAccount) } else { keychain.write(trimmed, account: Self.llmKeyAccount) }
        // Read back: a Keychain write can fail silently, and the coach must not run with a missing key.
        hasLLMKey = keychain.readString(Self.llmKeyAccount)?.isEmpty == false
        mutate { $0.settings.llmEnabled = !trimmed.isEmpty }
        Task { await askCoachForToday() }
    }

    func clearSyncError() { syncError = nil }

    /// Preview/testing hook: replace state wholesale.
    func load(_ state: AppState) {
        self.state = state
        briefFingerprintCache = nil
    }
}

/// Reads only what the older-Notes retry needs from a ride file, skipping samples and routes.
private struct PendingNoteProbe: Decodable {
    let athleteID: String
    /// A current debrief (no refresh due) whose Intervals note has not been read back yet: exactly the
    /// rides `syncDebriefNote(for:)` would retry.
    let notePending: Bool

    private enum CodingKeys: String, CodingKey { case athleteID, debrief, debriefNote }
    private struct DebriefRevision: Decodable { let evidenceRevision: Int? }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        athleteID = try c.decode(String.self, forKey: .athleteID)
        // Synthesized Codable omits nil optionals, but an explicit null must read as absent too.
        let debrief = try c.decodeIfPresent(DebriefRevision.self, forKey: .debrief)
        var hasNote = false
        if c.contains(.debriefNote) { hasNote = try !c.decodeNil(forKey: .debriefNote) }
        notePending = debrief?.evidenceRevision == RideDebrief.evidenceRevision && !hasNote
    }
}
