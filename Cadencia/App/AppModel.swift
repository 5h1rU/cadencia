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

    let bluetooth: BluetoothManager
    let health: HealthKitService
    private let store: JSONStore
    private let keychain: KeychainStore
    private let transport: any HTTPTransport
    private var rideCache: [UUID: RideRecording] = [:]

    private static let stateFile = "state.json"
    private static let credentialAccount = "intervals.credential"
    private static let llmKeyAccount = "llm.apiKey"

    init(state: AppState, credential: IntervalsCredential?, store: JSONStore, keychain: KeychainStore,
         transport: any HTTPTransport, bluetooth: BluetoothManager = BluetoothManager(), health: HealthKitService = HealthKitService()) {
        self.state = state
        self.credential = credential
        self.store = store
        self.keychain = keychain
        self.transport = transport
        self.bluetooth = bluetooth
        self.health = health
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
        guard let proposal = FTPEstimator().proposal(current: current, estimate: estimate) else { return nil }
        return proposal == state.dismissedFTPProposal ? nil : proposal
    }

    var pendingUploads: [UploadEntry] { state.ledger.pending(for: athleteID) }

    var hasLLMKey: Bool { keychain.readString(Self.llmKeyAccount)?.isEmpty == false }

    var client: IntervalsClient? {
        credential.map { IntervalsClient(transport: transport, credential: $0, athleteID: athleteID) }
    }

    private var coachEngine: any CoachEngine {
        if state.settings.llmEnabled, let key = keychain.readString(Self.llmKeyAccount), !key.isEmpty {
            return LLMCoach(transport: transport, endpoint: state.settings.llmEndpoint, apiKey: key, model: state.settings.llmModel)
        }
        return HeuristicCoach()
    }

    // MARK: Lifecycle

    func start() async {
        if state.today?.day != today { prescribeToday() }
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
        prescribeToday()
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
        prescribeToday()
    }

    // MARK: Today

    /// Recomputes readiness and the concrete workout for today. Rides already started today keep their workout.
    func prescribeToday() {
        let day = today
        if state.rideIndex.contains(where: { Day($0.startedAt) == day }), state.today?.day == day { return }
        let todayWellness = state.wellness(on: day) ?? WellnessDay(day: day)
        let readiness = ReadinessEngine().evaluate(today: todayWellness, history: state.wellness, feedback: state.feedback(for: day))
        let ftp = workingFTP ?? 200
        let input = DailyPrescriber.Input(day: day, planned: plannedToday, readiness: readiness, ftp: ftp,
                                          availableMinutes: nil, upcomingPriorityEvent: upcomingEvent)
        let workout = DailyPrescriber().prescribe(input)
        mutate { s in
            s.today = AppState.TodayState(day: day, workout: workout, readiness: readiness)
            if let i = s.plan?.sessions.firstIndex(where: { $0.day == day }),
               let status = s.plan?.sessions[i].status, status == .provisional || status == .generated {
                s.plan?.sessions[i].workout = workout
                s.plan?.sessions[i].status = .generated
            }
        }
    }

    func recordFeeling(_ legs: SubjectiveFeedback.Legs?, motivation: Int? = nil) {
        var fb = state.feedback(for: today) ?? SubjectiveFeedback(day: today)
        fb.legs = legs
        if let motivation { fb.motivation = motivation }
        mutate { $0.setFeedback(fb) }
        prescribeToday()
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
        prescribeToday()
    }

    func keepCurrentFTP() {
        mutate { $0.dismissedFTPProposal = ftpProposal }
    }

    /// Drops the locally accepted FTP so the Intervals value becomes the working FTP again.
    func useIntervalsFTP() {
        mutate { $0.acceptedFTP = nil; $0.dismissedFTPProposal = nil }
        prescribeToday()
    }

    // MARK: Plan

    func createPlan(_ request: PlanBuilder.Request) async {
        var plan = PlanBuilder().build(request)
        plan.isActive = true
        mutate { $0.plan = plan }
        prescribeToday()
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
        prescribeToday()
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
        if let legs = intent.feeling { recordFeeling(legs) } else { prescribeToday() }
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
        do {
            let intent = try await coachEngine.interpret(trimmed, context: context)
            mutate { $0.coachMessages.append(.init(role: .coach, text: intent.reply, intent: intent)) }
        } catch {
            mutate { $0.coachMessages.append(.init(role: .coach, text: String(localized: "I could not process that right now. Try again, or type it."))) }
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
    }

    func clearSyncError() { syncError = nil }

    /// Preview/testing hook: replace state wholesale.
    func load(_ state: AppState) { self.state = state }
}
