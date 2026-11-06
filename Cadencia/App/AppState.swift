import Foundation
import CadenciaCore

/// Everything the app persists besides credentials (Keychain) and ride samples (one file per ride).
struct AppState: Codable, Equatable {
    struct Settings: Codable, Equatable {
        var ergByDefault = true
        var pushWellnessToIntervals = false
        var writeWorkoutsToHealth = true
        var readHealth = true
        var llmEnabled = false
        var llmEndpoint = AppConfig.defaultLLMEndpoint
        var llmModel = AppConfig.defaultLLMModel
        var unitsMetric = true
        /// The coach speaks during rides (block starts, long-block midpoints, the finish).
        var rideVoice = true
        /// The same lines shown as captions on the ride screen.
        var rideCaptions = true
        /// OpenAI voice for the ride coach when an API key is configured; the ChatGPT plan path uses the phone's voice.
        var coachVoice = CoachVoice.defaultVoice
        var outdoorDevice: OutdoorDevice = .garmin

        init() {}

        /// Every key is optional on the way in, so a setting added in a later version never makes an
        /// older `AppState` file undecodable (which would silently reset the whole app).
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            ergByDefault = try c.decodeIfPresent(Bool.self, forKey: .ergByDefault) ?? ergByDefault
            pushWellnessToIntervals = try c.decodeIfPresent(Bool.self, forKey: .pushWellnessToIntervals) ?? pushWellnessToIntervals
            writeWorkoutsToHealth = try c.decodeIfPresent(Bool.self, forKey: .writeWorkoutsToHealth) ?? writeWorkoutsToHealth
            readHealth = try c.decodeIfPresent(Bool.self, forKey: .readHealth) ?? readHealth
            llmEnabled = try c.decodeIfPresent(Bool.self, forKey: .llmEnabled) ?? llmEnabled
            llmEndpoint = try c.decodeIfPresent(URL.self, forKey: .llmEndpoint) ?? llmEndpoint
            llmModel = try c.decodeIfPresent(String.self, forKey: .llmModel) ?? llmModel
            unitsMetric = try c.decodeIfPresent(Bool.self, forKey: .unitsMetric) ?? unitsMetric
            rideVoice = try c.decodeIfPresent(Bool.self, forKey: .rideVoice) ?? rideVoice
            rideCaptions = try c.decodeIfPresent(Bool.self, forKey: .rideCaptions) ?? rideCaptions
            coachVoice = try c.decodeIfPresent(String.self, forKey: .coachVoice) ?? coachVoice
            outdoorDevice = try c.decodeIfPresent(OutdoorDevice.self, forKey: .outdoorDevice) ?? outdoorDevice
        }
    }

    struct TodayState: Codable, Equatable {
        var day: Day
        /// The workout to ride today: the one the plan accepted (the `TodayDecision` view), or the coach's
        /// own on a day without a plan, which the backend has nothing to record against.
        var workout: Workout
        var readiness: Readiness
        /// The coach's note and model for that workout, as the decision recorded them.
        var note: CoachNote?
        var model: String?
        var decidedAt: Date?
        /// `CoachBrief.fingerprint` of the inputs the decision was made from (the evidence's fingerprint);
        /// a different one means ask again.
        var aiFingerprint: String?
        var rideLocation: RideLocation?
        var prescriptionFTP: Int?
        var outdoorHandoff: OutdoorHandoff?
        /// Survives plan changes and restarts, including a daily workout recorded without a plan.
        var completedRideID: UUID?

        var isAICoached: Bool { model != nil }
    }

    struct OutdoorHandoff: Codable, Equatable {
        var revision: String
        var eventID: Int
        var savedAt: Date
    }

    /// A view of the backend kept for the next launch. It decodes to nil, never fails the whole state, when the
    /// backend's shape changed: the next read fills it again.
    struct ViewCache<Value: Codable & Equatable>: Codable, Equatable {
        var value: Value?
        init(_ value: Value?) { self.value = value }
        init(from decoder: Decoder) throws { value = try? decoder.singleValueContainer().decode(Value.self) }
        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            try c.encode(value)
        }
    }

    /// The consultation the athlete has open, by its backend id, and its view.
    struct ConsultationCache: Codable, Equatable {
        var id: String
        var startedOn: Day
        var view: ViewCache<CadenciaAPI.ConsultationViewState>
    }

    struct PendingProfileWeight: Codable, Equatable {
        var day: Day
        var kg: Double
    }

    /// Cache of Intervals' athlete: FTP, height, units and weekly availability live there.
    var athlete: AthleteProfile?
    /// An FTP the athlete accepted in the app that Intervals does not hold yet (the Ride sport settings).
    /// Cleared once the write is confirmed; until then it is the working FTP.
    var acceptedFTP: Int?
    var wellness: [WellnessDay] = []
    var activities: [ActivitySummary] = []
    /// Optional for states saved before calendar reads were used as coaching context.
    var calendarEvents: [IntervalsEvent]?
    var powerCurve: [PowerCurvePoint] = []
    var ftpEstimate: FTPEstimate?
    var dismissedFTPProposal: Int?
    /// The backend's `CurrentPlan` view in the app's terms (`TrainingPlan(_:context:)`), with what Intervals
    /// adds: completed sessions and the plan's availability, time away and other training. Only reading the
    /// view or Intervals changes it; every change to the plan itself is a command to the backend.
    var plan: TrainingPlan?
    /// The Intervals-native and device-only parts of the current plan (`PlanContext`).
    var planContext: PlanContext?
    /// Daily sessions exported without a plan remain identifiable when a ride syncs on a later day.
    var standaloneSessions: [PlannedSession]?
    /// Independent of coach revisions: softening/removing a prescription never deletes a course.
    var rideRoutePlans: [String: RideRoutePlan]?
    struct RideRoutePlan: Codable, Equatable {
        var route: GPXRoute
        var fileName: String
        var sourceIndex: Int
        var minutes: Int
    }
    var today: TodayState?
    /// Cache of Intervals' wellness (feel, sleep, motivation, mood, stress, injury, comments) plus each
    /// ride's RPE. Rebuilt from every wellness read; local edits wait in `intervalsOutbox`.
    var feedbackByDay: [String: SubjectiveFeedback] = [:]
    var ledger = UploadLedger()
    var rideIndex: [RideIndexEntry] = []
    /// Caches of the backend's views: this month's conversation, today's decision, the rider profile and the
    /// open consultation. The backend holds them; these only show them until the next read.
    var coachThread: ViewCache<CadenciaAPI.ConversationThreadState>?
    var todayDecision: ViewCache<CadenciaAPI.TodayDecisionState>?
    var riderProfile: ViewCache<CadenciaAPI.RiderProfileCardState>?
    var consultation: ConsultationCache?
    var cyclistMeasurements: CyclistMeasurements?
    /// Superseded by `intervalsOutbox`; read once by the version 1 migration.
    var profileWeightPendingSync: PendingProfileWeight?
    /// Superseded by `retiredCalendarEvents`; read once by the version 1 migration.
    var retiredPlanEventIDs: [Int]?
    /// Changes not yet confirmed by Intervals. Optional so older state files decode.
    var intervalsOutbox: IntervalsOutbox?
    /// What Cadencia last wrote for its non-ride calendar entries (goal event, time away, other training).
    var calendarEntryBase: [String: CalendarEntryBase]?
    /// Planned rides of a replaced or discarded plan, deleted by external id (and server id when known).
    var retiredCalendarEvents: [CalendarSync.Deletion]?
    /// `IntervalsMigration.version` once local-only data has been queued for Intervals.
    var intervalsMigrationVersion: Int?
    /// Persisted before the first automatic request, including failed/cancelled attempts.
    var cyclistProfileAutomaticAttemptedAt: Date?
    var settings = Settings()
    var lastSyncAt: Date?
    var lastHealthReadAt: Date?
    var healthAuthorized = false
    /// OpenAI asks for the "You're using your ChatGPT plan" notice exactly once.
    /// Optional on purpose: a new non-optional key would make the existing state.json undecodable.
    var chatGPTWelcomeShownAt: Date?

    struct RideIndexEntry: Codable, Equatable, Identifiable {
        var id: UUID
        var name: String
        var kind: SessionKind
        var startedAt: Date
        var duration: TimeInterval
        var averageWatts: Int?
        var load: Int?
    }

    var workingFTP: Int? { (acceptedFTP ?? athlete?.workingFTP).flatMap { $0 > 0 ? $0 : nil } }

    var profileWeight: CyclistMeasurements.Measurement? {
        let local = cyclistMeasurements?.weight
        if let day = wellness.last(where: { ($0.weightKg ?? 0) > 0 }), let kg = day.weightKg, kg.isFinite,
           local.map({ day.day > Day($0.measuredAt) }) ?? true {
            return .init(value: kg, measuredAt: day.day.date(), source: .intervals)
        }
        if let local { return local }
        guard let kg = athlete?.weightKg, kg.isFinite, kg > 0 else { return nil }
        return .init(value: kg, measuredAt: .distantPast, source: .intervals)
    }

    var weightKg: Double? { profileWeight?.value }

    var heightCm: Double? { cyclistMeasurements?.height?.value }

    func feedback(for day: Day) -> SubjectiveFeedback? { feedbackByDay[day.iso] }

    /// The rider profile the backend recorded.
    var cyclistProfile: CyclistProfile.Report? { riderProfile?.value.flatMap(CyclistProfile.Report.init) }

    /// This month's conversation with the coach, oldest first.
    var coachMessages: [CadenciaAPI.ThreadMessage] { coachThread?.value?.messages ?? [] }

    /// What the athlete asked of `day`, as the plan recorded it.
    func workoutRequest(on day: Day) -> CoachIntent.WorkoutRequest? {
        plan?.requirements?.first { $0.day == day }
    }

    /// What the athlete told the coach lately and the plan took on: the messages whose proposals were applied.
    func appliedCoachNotes(on day: Day) -> [String] {
        let messages = coachMessages
        return messages.indices.compactMap { index -> String? in
            let message = messages[index]
            guard message.role == .coach, message.intentStatus == .applied,
                  let at = BackendDate.parse(message.at), at > day.adding(days: -7).date() else { return nil }
            return messages[..<index].last { $0.role == .athlete }?.text
        }.suffix(5).map { $0 }
    }

    /// Today's workout from a decision: the plan's accepted one, or the coach's own on a day without a plan.
    mutating func takeDecision(workout: Workout, readiness: Readiness, note: CoachNote?, model: String?, day: Day, ftp: Int?) {
        guard !isWorkoutCompleted(on: day) else { return }
        let previous = today?.day == day ? today : nil
        today = TodayState(day: day, workout: workout, readiness: readiness, note: note, model: model, decidedAt: Date())
        today?.rideLocation = previous?.rideLocation
        today?.prescriptionFTP = ftp
        if let i = plan?.sessions.firstIndex(where: { $0.day == day }), let status = plan?.sessions[i].status,
           status == .provisional || status == .generated {
            plan?.sessions[i].workout = workout
            plan?.sessions[i].status = .generated
            plan?.sessions[i].prescriptionFTP = ftp
        } else if let i = standaloneSessions?.firstIndex(where: { $0.day == day && $0.status != .completed && $0.status != .skipped }) {
            standaloneSessions?[i].workout = workout
            standaloneSessions?[i].status = .generated
            standaloneSessions?[i].kind = workout.kind
            standaloneSessions?[i].title = workout.name
            standaloneSessions?[i].targetMinutes = Int((workout.totalDuration / 60).rounded())
            standaloneSessions?[i].targetLoad = workout.estimatedLoad
            standaloneSessions?[i].prescriptionFTP = ftp
        } else if session(on: day) == nil, workout.kind != .rest {
            if standaloneSessions == nil { standaloneSessions = [] }
            standaloneSessions?.append(PlannedSession(day: day, kind: workout.kind, title: workout.name,
                targetMinutes: Int((workout.totalDuration / 60).rounded()), targetLoad: workout.estimatedLoad,
                status: .generated, workout: workout, location: today?.rideLocation, prescriptionFTP: ftp))
        }
    }

    /// Replaces the plan with the backend's `CurrentPlan` view, and lays over it what Intervals holds: the
    /// sessions' calendar events and completed rides, availability, time away and other training.
    mutating func adoptBackendPlan(_ view: CadenciaAPI.CurrentPlanState?) {
        let fresh = view.flatMap { TrainingPlan($0, context: planContext) }
        if let fresh, planContext?.planId != fresh.backendID { planContext = nil }
        if fresh == nil { planContext = nil }
        plan = fresh.map { plan in
            var plan = plan
            let events = calendarEvents ?? []
            for i in plan.sessions.indices {
                plan.sessions[i].intervalsEventID = PlanMirror.existingEvent(for: plan.sessions[i], in: events)?.id
                if plan.sessions[i].day == today?.day, let today, today.workout.kind == plan.sessions[i].kind,
                   plan.sessions[i].workout == nil || plan.sessions[i].workout?.name == today.workout.name {
                    plan.sessions[i].prescriptionFTP = today.prescriptionFTP
                }
            }
            if let days = athlete?.trainingAvailability, planContext?.availability != nil {
                plan.availability = IntervalsAvailability.applying(days, to: plan.availability)
            }
            return plan
        }
        adoptIntervalsCompletion(activities)
    }

    /// Shows the feedback at once and queues what changed for the day's Intervals wellness record.
    mutating func setFeedback(_ feedback: SubjectiveFeedback) {
        let previous = feedbackByDay[feedback.day.iso]
        feedbackByDay[feedback.day.iso] = feedback
        enqueue(WellnessUpdate(changingFrom: previous, to: feedback))
    }

    mutating func enqueue(_ update: WellnessUpdate) {
        guard !update.isEmpty else { return }
        var outbox = intervalsOutbox ?? IntervalsOutbox()
        outbox.enqueue(update)
        intervalsOutbox = outbox
    }

    mutating func updateOutbox(_ body: (inout IntervalsOutbox) -> Void) {
        var outbox = intervalsOutbox ?? IntervalsOutbox()
        body(&outbox)
        intervalsOutbox = outbox.isEmpty ? nil : outbox
    }

    /// The plan's weekly availability as Intervals' `training_availability`, other training included.
    var planAvailability: [IntervalsAvailabilityDay]? {
        guard let plan, plan.isActive else { return nil }
        return IntervalsAvailability.days(from: plan.availability,
            otherSports: IntervalsAvailability.otherSports(plan.consultation?.otherTraining ?? []))
    }

    var hasPendingProfileSync: Bool {
        intervalsOutbox.map { $0.heightCm != nil || $0.wellness.contains { $0.weightKg != nil } } ?? false
            || profileWeightPendingSync != nil
    }

    // MARK: Reading Intervals back

    /// Athlete-level values from Intervals, except where a local change is still on its way there.
    mutating func adoptIntervalsAthlete(_ fresh: AthleteProfile) {
        athlete = fresh
        let outbox = intervalsOutbox ?? IntervalsOutbox()
        if let ftp = acceptedFTP, IntervalsAthleteFields.holds(ftp: ftp, athlete: fresh) { acceptedFTP = nil }
        if outbox.heightCm == nil, let cm = fresh.heightCm,
           cyclistMeasurements?.height.map({ abs($0.value - cm) >= 0.5 }) ?? true {
            var m = cyclistMeasurements ?? CyclistMeasurements()
            m.height = .init(value: cm, measuredAt: Date(), source: .intervals)
            cyclistMeasurements = m
        }
        if outbox.measurementPreference == nil, let metric = IntervalsAthleteFields.isMetric(fresh.measurementPreference) {
            settings.unitsMetric = metric
        }
        if outbox.availability == nil, let days = fresh.trainingAvailability, var current = plan, current.isActive {
            current.availability = IntervalsAvailability.applying(days, to: current.availability)
            if var details = current.consultation {
                details.weeklyRides = IntervalsAvailability.applying(current.availability, to: details.weeklyRides)
                current.consultation = details
            }
            plan = current
            if planContext?.planId == current.backendID {
                planContext?.availability = current.availability
                planContext?.details = current.consultation
            }
        }
    }

    /// Intervals' wellness over `range`: subjective fields replace the cache (a field cleared in Intervals
    /// is cleared here), the feedback cache is rebuilt with queued edits on top, and queued edits Intervals
    /// already shows are dropped.
    mutating func adoptIntervalsWellness(_ days: [WellnessDay], range: ClosedRange<Day>) {
        var byDay = Dictionary(uniqueKeysWithValues: wellness.map { ($0.day, $0) })
        for d in days { byDay[d.day] = IntervalsReadBack.wellness(byDay[d.day], remote: d) }
        wellness = byDay.values.sorted { $0.day < $1.day }
        updateOutbox { $0.dropReflected(in: days) }
        feedbackByDay = IntervalsReadBack.feedback(cached: feedbackByDay, remote: days, range: range,
                                                   pending: intervalsOutbox?.wellness ?? [])
    }

    /// Sessions whose Intervals event has a paired activity are completed, with its compliance.
    mutating func adoptIntervalsCompletion(_ activities: [ActivitySummary]) {
        func apply(_ session: inout PlannedSession) {
            guard let compliance = PlanMirror.completion(for: session, activities: activities) else { return }
            session.status = .completed
            session.compliance = compliance
        }
        if var p = plan { for i in p.sessions.indices { apply(&p.sessions[i]) }; plan = p }
        if var s = standaloneSessions { for i in s.indices { apply(&s[i]) }; standaloneSessions = s }
    }

    /// Edits made in the Intervals calendar over `window`: the goal event and time away of the plan, and a
    /// daily workout's indoor flag, FTP and type. Only what Cadencia has not changed since its last write is
    /// taken. The plan's own sessions are the backend's: it notices their changes in Intervals itself.
    mutating func adoptIntervalsCalendar(_ events: [IntervalsEvent], window: ClosedRange<Day>, today: Day) {
        func adopt(_ session: inout PlannedSession) {
            guard window.contains(session.day), let event = PlanMirror.existingEvent(for: session, in: events),
                  PlanMirror.adopt(event, into: &session) else { return }
            if session.day == today, self.today?.day == today { self.today?.rideLocation = session.location }
        }
        if var p = plan {
            for i in p.sessions.indices { p.sessions[i].intervalsEventID = PlanMirror.existingEvent(for: p.sessions[i], in: events)?.id }
            if CalendarSync.adopt(events, window: window, into: &p, base: calendarEntryBase ?? [:]), planContext?.planId == p.backendID {
                planContext?.details = p.consultation
                if let event = p.event { planContext?.event = event }
            }
            plan = p
        }
        if var s = standaloneSessions { for i in s.indices { adopt(&s[i]) }; standaloneSessions = s }
    }

    func wellness(on day: Day) -> WellnessDay? { wellness.first { $0.day == day } }

    func session(on day: Day) -> PlannedSession? {
        guard var session = plan?.sessions.first(where: { $0.day == day }) ?? standaloneSessions?.first(where: { $0.day == day }) else { return nil }
        if let attachment = rideRoutePlans?[day.iso] {
            session.route = attachment.route; session.routeFileName = attachment.fileName; session.routeSourceIndex = attachment.sourceIndex
        }
        return session
    }

    func routePlan(on day: Day) -> RideRoutePlan? {
        if let saved = rideRoutePlans?[day.iso] { return saved }
        guard let session = session(on: day), let route = session.route else { return nil }
        return RideRoutePlan(route: route, fileName: session.routeFileName ?? "route.gpx", sourceIndex: session.routeSourceIndex ?? 0, minutes: session.targetMinutes)
    }

    func isWorkoutCompleted(on day: Day) -> Bool {
        (today?.day == day && today?.completedRideID != nil) || session(on: day)?.status == .completed
    }

    mutating func completeSession(for ride: RideRecording) {
        guard ride.endedAt != nil else { return }
        if let i = plan?.sessions.firstIndex(where: { ride.completes($0) }) {
            plan?.sessions[i].status = .completed
        }
        if let i = standaloneSessions?.firstIndex(where: { ride.completes($0) }) {
            standaloneSessions?[i].status = .completed
        }
        if let current = today, current.day == Day(ride.startedAt),
           ride.workout.id == current.workout.id || session(on: current.day).map({ ride.completes($0) }) == true {
            today?.completedRideID = ride.id
            today?.outdoorHandoff = nil
        }
    }

    mutating func mergeWellness(_ days: [WellnessDay]) {
        var byDay = Dictionary(uniqueKeysWithValues: wellness.map { ($0.day, $0) })
        for d in days { byDay[d.day] = byDay[d.day].map { $0.merging(d) } ?? d }
        wellness = byDay.values.sorted { $0.day < $1.day }
    }
}
