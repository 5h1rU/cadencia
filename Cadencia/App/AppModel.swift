import Foundation
import Observation
import CadenciaCore

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

    enum CoachIssue: Equatable {
        case usageLimit, notEligible, signInAgain
    }

    let bluetooth: BluetoothManager
    let health: HealthKitService
    private let store: JSONStore
    private let keychain: KeychainStore
    private let transport: any HTTPTransport
    private var rideCache: [UUID: RideRecording] = [:]

    private static let stateFile = "state.json"
    private static let credentialAccount = "intervals.credential"
    private static let llmKeyAccount = "llm.apiKey"
    private static let chatGPTAccount = "chatgpt.credential"
    private static let chatGPTClientIDAccount = "chatgpt.clientID"
    private static let chatGPTHostIDAccount = "chatgpt.hostID"

    init(state: AppState, credential: IntervalsCredential?, store: JSONStore, keychain: KeychainStore,
         transport: any HTTPTransport, bluetooth: BluetoothManager = BluetoothManager(), health: HealthKitService = HealthKitService()) {
        self.state = state
        self.credential = credential
        self.store = store
        self.keychain = keychain
        self.transport = transport
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
    var plannedToday: PlannedSession? { state.plan?.sessions.first { $0.day == today } }
    var todayWellness: WellnessDay? { state.wellness(on: today) }
    var latestWellness: WellnessDay? { state.wellness.last }

    var upcomingEvent: TrainingEvent? {
        guard let e = state.plan?.event, e.day >= today else { return nil }
        return e
    }

    var thisWeekEvent: TrainingEvent? {
        guard let e = upcomingEvent, e.day <= today.adding(days: 7) else { return nil }
        return e
    }

    var ftpProposal: Int? {
        guard let current = workingFTP, let estimate = state.ftpEstimate else { return nil }
        let since = today.adding(days: -estimate.windowDays)
        let recentEFTP = state.activities.filter { $0.isCycling && $0.day >= since }.compactMap(\.estimatedFTP).max()
        guard let proposal = FTPEstimator().proposal(current: current, estimate: estimate, recentEFTP: recentEFTP) else { return nil }
        return proposal == state.dismissedFTPProposal ? nil : proposal
    }

    /// The coach's note at the top of Today, in the AI coach's own words. Nil until it has decided the day.
    var coachNote: String? {
        guard let t = state.today, t.day == today, let ai = t.ai else { return nil }
        let note = [ai.readiness.summary, ai.coachNote].filter { !$0.isEmpty }.joined(separator: " ")
        return note.isEmpty ? nil : note
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
    var aiCoachAvailable: Bool { coachSource != nil }

    /// Resolves the coach for one request, refreshing the ChatGPT token first when it is about to expire.
    /// Nil when the ChatGPT sign-in is dead (`coachIssue` is set) and no API key exists.
    private func coachEngine() async -> LLMCoach? {
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

    // MARK: Lifecycle

    func start() async {
        guard isSignedIn else { return }
        await refresh()
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
        keychain.delete(Self.credentialAccount)
        bluetooth.disconnectAll()
        mutate {
            $0.wellness = []
            $0.activities = []
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
        isSyncing = true
        defer { isSyncing = false }

        // Each fetch is independent: a failing request (for example a malformed power-curve query)
        // must not discard the athlete, wellness, and activities that did arrive. The first failure
        // is surfaced; an auth failure wins over everything else because the user has to act on it.
        var failures: [(String, Error)] = []

        do {
            let athlete = try await client.athlete()
            mutate { $0.athlete = athlete }
        } catch { failures.append(("athlete", error)) }

        if (failures.first?.1 as? HTTPError)?.isAuthFailure == true {
            syncError = String(localized: "Intervals rejected the credential. Reconnect in Settings.")
        } else {
            do {
                let wellness = try await client.wellness(oldest: today.adding(days: -90), newest: today)
                mutate { $0.mergeWellness(wellness) }
            } catch { failures.append(("wellness", error)) }

            do {
                let activities = try await client.activities(oldest: today.adding(days: -42), newest: today)
                mutate { $0.activities = activities }
            } catch { failures.append(("activities", error)) }

            do {
                let curve = try await client.powerCurve(newest: today)
                mutate { $0.powerCurve = curve }
            } catch { failures.append(("power curve", error)) }

            if failures.count < 4 {
                mutate { $0.lastSyncAt = Date() }
            }
            syncError = failures.first.map { "Intervals \($0.0): \($0.1.localizedDescription)" }
        }

        await readHealth()
        recomputeFTPEstimate()
        await askCoachForToday()
        await runUploads()
        await pushWeekToIntervals()
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
    private func measuredToday() -> Readiness {
        let day = today
        let todayWellness = state.wellness(on: day) ?? WellnessDay(day: day)
        return ReadinessEngine().evaluate(today: todayWellness, history: state.wellness, feedback: state.feedback(for: day))
    }

    /// Everything the AI coach is shown. Built fresh each time so the fingerprint tracks the real inputs.
    private func coachBrief() -> CoachBrief {
        let recentNotes = state.coachMessages.filter { $0.role == .athlete && $0.sentAt > today.adding(days: -7).date() }.suffix(5).map(\.text)
        return CoachBrief(today: today, locale: coachLocale,
                          athlete: .init(ftp: workingFTP ?? 200, weightKg: state.athlete?.weightKg ?? latestWellness?.weightKg,
                                         maxHR: state.athlete?.maxHR, lthr: state.athlete?.lthr),
                          ftpEstimate: state.ftpEstimate, powerCurve: state.powerCurve,
                          wellness: state.wellness, feedback: feedbackIndex, activities: state.activities,
                          plan: state.plan, upcomingEvent: upcomingEvent, availableMinutes: nil, recentCoachNotes: Array(recentNotes),
                          measured: measuredToday())
    }

    private var feedbackIndex: [Day: SubjectiveFeedback] {
        Dictionary(uniqueKeysWithValues: state.feedbackByDay.values.map { ($0.day, $0) })
    }

    private var coachLocale: String { Locale.current.language.languageCode?.identifier ?? "es" }

    /// Today's measured signals even before the coach has answered (the Recovery row shows them).
    var measuredSignals: Readiness { state.today?.day == today ? state.today!.readiness : measuredToday() }

    /// Asks the coach again from synchronous call sites (feedback, FTP change, plan change).
    private func reaskCoach() {
        Task { await askCoachForToday() }
    }

    /// Asks the language model for today's decision when the inputs changed since the last answer
    /// (or always, with `force`). Keeps the rule-based baseline on any failure; plan problems become `coachIssue`.
    func askCoachForToday(force: Bool = false) async {
        guard !coachThinking else { return }
        let day = today
        let brief = coachBrief()
        if !force, let current = state.today, current.day == day, current.aiFingerprint == brief.fingerprint { return }

        guard let engine = await coachEngine() else {
            coachNotice = coachSource == nil ? nil : String(localized: "ChatGPT no longer accepts this sign-in. Sign in again in Settings → Coach.")
            return
        }
        coachThinking = true
        defer { coachThinking = false }
        do {
            let prescription = try await engine.prescribe(brief: brief)
            guard today == day else { return }
            mutate { s in
                s.today = AppState.TodayState(day: day, workout: prescription.workout, readiness: prescription.readiness, ai: prescription)
                s.attachTodayWorkout(prescription.workout, day: day)
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
        } catch let error as LLMCoachError {
            switch error {
            case .usageLimitReached: coachIssue = .usageLimit
            case .notEligible: coachIssue = .notEligible
            case .unauthorized: coachIssue = .signInAgain
            }
        } catch let error as DailyPrescription.ValidationError {
            coachNotice = String(localized: "The coach's answer failed a safety check (\(String(describing: error))). Ask again.")
        } catch let error as LLMCoach.CompletionError {
            coachNotice = String(localized: "The coach could not be reached (\(String(describing: error))). Ask again.")
        } catch {
            coachNotice = String(localized: "The coach could not be reached (\(error.localizedDescription)). Ask again.")
        }
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
                if session.kind != outlook.kind, session.day != today { session.workout = nil; session.status = .provisional }
                session.kind = outlook.kind
                session.title = outlook.title
                session.targetMinutes = outlook.minutes
                session.note = outlook.note
                plan.sessions[i] = session
            } else if outlook.kind != .rest, outlook.minutes > 0 {
                plan.sessions.append(PlannedSession(day: outlook.day, kind: outlook.kind, title: outlook.title,
                                                    targetMinutes: outlook.minutes, note: outlook.note))
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
        guard var plan = state.plan ?? intent.event.map({ event in
            PlanBuilder().build(.init(goal: .event, startDay: today, endDay: event.day, event: event, availability: .typical))
        }) else { return }
        plan.isActive = true
        let revision = WeekReviser().apply(intent, to: plan, today: today)
        mutate {
            $0.plan = revision.plan
            if let messageID, let i = $0.coachMessages.firstIndex(where: { $0.id == messageID }) { $0.coachMessages[i].applied = true }
        }
        if let legs = intent.feeling {
            var fb = state.feedback(for: today) ?? SubjectiveFeedback(day: today)
            fb.legs = legs
            mutate { $0.setFeedback(fb) }
        }
        await askCoachForToday()
        await pushWeekToIntervals()
    }

    /// Mirrors the next seven days to the Intervals calendar so other tools (and the athlete's watch) see them.
    func pushWeekToIntervals() async {
        guard let client, let plan = state.plan, let ftp = workingFTP else { return }
        let horizon = today.adding(days: 7)
        for session in plan.sessions where session.day >= today && session.day <= horizon && session.status != .completed {
            if let event = try? await client.upsertPlannedWorkout(session, ftp: ftp) {
                mutate {
                    if let i = $0.plan?.sessions.firstIndex(where: { $0.id == session.id }) { $0.plan?.sessions[i].intervalsEventID = event.id }
                }
            }
        }
    }

    // MARK: Coach

    func sendToCoach(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !coachBusy else { return }
        coachBusy = true
        defer { coachBusy = false }
        mutate { $0.coachMessages.append(.init(role: .athlete, text: trimmed)) }
        let context = CoachContext(today: today, locale: Locale.current.language.languageCode?.identifier ?? "es",
                                   readiness: readiness, plan: state.plan, recentActivities: Array(state.activities.suffix(10)), ftp: workingFTP)
        // When the ChatGPT refresh token is dead `freshChatGPTCredential` sets `coachIssue = .signInAgain`;
        // the Coach screen shows that as a banner with a sign-in action.
        guard let engine = await coachEngine() else {
            mutate { $0.coachMessages.append(.init(role: .coach, text: String(localized: "Connect ChatGPT (or an API key) in Settings → Coach first."))) }
            return
        }
        do {
            let intent = try await engine.interpret(trimmed, context: context)
            mutate { $0.coachMessages.append(.init(role: .coach, text: intent.reply, intent: intent)) }
        } catch let error as LLMCoachError {
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
        } catch {
            mutate { $0.coachMessages.append(.init(role: .coach, text: String(localized: "I could not reach the coach right now (\(error.localizedDescription)). Try again."))) }
        }
    }

    func clearCoachHistory() { mutate { $0.coachMessages = [] } }

    // MARK: Rides

    func ride(id: UUID) -> RideRecording? {
        if let r = rideCache[id] { return r }
        let r = store.load(RideRecording.self, at: "rides/\(id.uuidString).json")
        if let r { rideCache[id] = r }
        return r
    }

    func finishRide(_ recording: RideRecording) async {
        rideCache[recording.id] = recording
        do { try store.save(recording, at: "rides/\(recording.id.uuidString).json") } catch { syncError = error.localizedDescription }
        let ftp = workingFTP ?? 200
        mutate {
            $0.rideIndex.append(.init(id: recording.id, name: recording.workout.name, kind: recording.workout.kind, startedAt: recording.startedAt,
                                      duration: recording.duration, averageWatts: recording.averageWatts, load: recording.trainingLoad(ftp: ftp)))
            $0.ledger.enqueue(rideID: recording.id, athleteID: recording.athleteID)
            if let sid = recording.plannedSessionID, let i = $0.plan?.sessions.firstIndex(where: { $0.id == sid }) {
                $0.plan?.sessions[i].status = .completed
            }
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
            guard let ride = ride(id: entry.rideID) else { continue }
            mutate { $0.ledger.markAttempt(entry.rideID, at: now) }
            if entry.state == .uncertain {
                if let existing = try? await client.activity(externalID: ride.externalID, around: Day(ride.startedAt)) {
                    mutate { $0.ledger.markConfirmed(entry.rideID, activityID: existing.id, at: Date()) }
                    await syncFeedback(for: entry.rideID)
                    continue
                }
            }
            do {
                let result = try await client.uploadActivity(tcx: TCXEncoder.encode(ride, name: ride.workout.name), name: ride.workout.name,
                                                             externalID: ride.externalID, pairedEventID: ride.intervalsEventID)
                mutate { $0.ledger.markConfirmed(entry.rideID, activityID: result.activityID, at: Date()) }
                await syncFeedback(for: entry.rideID)
            } catch let error as HTTPError {
                mutate { $0.ledger.markFailure(entry.rideID, error: error, requestWasSent: true) }
            } catch {
                mutate { $0.ledger.markFailure(entry.rideID, error: .transport(error.localizedDescription), requestWasSent: true) }
            }
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
