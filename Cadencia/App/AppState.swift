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
        var workout: Workout
        var readiness: Readiness
        /// The AI coach's decision, when one was accepted for this day. `workout`/`readiness` already
        /// reflect it; this keeps the note, the week outlook, flags and the model for the UI.
        /// Optional so a state saved before the AI coach still decodes.
        var ai: DailyPrescription?
        /// `CoachBrief.fingerprint` of the inputs `ai` was computed from; a different one means re-ask.
        var aiFingerprint: String?
        var rideLocation: RideLocation?
        var prescriptionFTP: Int?
        var outdoorHandoff: OutdoorHandoff?
        /// Survives plan changes and restarts, including a daily workout recorded without a plan.
        var completedRideID: UUID?

        var isAICoached: Bool { ai != nil }
    }

    struct OutdoorHandoff: Codable, Equatable {
        var revision: String
        var eventID: Int
        var savedAt: Date
    }

    struct CoachMessage: Codable, Equatable, Identifiable {
        enum Role: String, Codable { case athlete, coach }
        var id = UUID()
        var role: Role
        var text: String
        var sentAt = Date()
        var intent: CoachIntent?
        var applied = false
        var sourceMessageID: UUID?
        var workoutProposal: WorkoutProposal?
    }

    struct WorkoutProposal: Codable, Equatable {
        var prescription: DailyPrescription
        var basisFingerprint: String
        var ftp: Int
    }

    struct PendingProfileWeight: Codable, Equatable {
        var day: Day
        var kg: Double
    }

    var athlete: AthleteProfile?
    /// FTP the athlete accepted in the app. Falls back to the Intervals value until a review is accepted.
    var acceptedFTP: Int?
    var wellness: [WellnessDay] = []
    var activities: [ActivitySummary] = []
    /// Optional for states saved before calendar reads were used as coaching context.
    var calendarEvents: [IntervalsEvent]?
    var powerCurve: [PowerCurvePoint] = []
    var ftpEstimate: FTPEstimate?
    var dismissedFTPProposal: Int?
    var plan: TrainingPlan?
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
    var feedbackByDay: [String: SubjectiveFeedback] = [:]
    var ledger = UploadLedger()
    var rideIndex: [RideIndexEntry] = []
    var coachMessages: [CoachMessage] = []
    /// Applied requirements survive refreshes, but only affect their own day.
    var workoutRequests: [String: CoachIntent.WorkoutRequest]?
    /// Optional for existing state files. Profile generation is independent of the daily coach.
    var cyclistProfile: CyclistProfile.Report?
    var cyclistMeasurements: CyclistMeasurements?
    var planConsultation: PlanConsultation.Session?
    var profileWeightPendingSync: PendingProfileWeight?
    var retiredPlanEventIDs: [Int]?
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

    func appliedCoachNotes(on day: Day) -> [String] {
        coachMessages.enumerated().compactMap { index, message in
            guard message.role == .coach, message.applied, message.sentAt > day.adding(days: -7).date(),
                  message.intent?.workoutRequest == nil else { return nil }
            if let id = message.sourceMessageID {
                return coachMessages.first { $0.id == id && $0.role == .athlete }?.text
            }
            // Messages from older app versions did not retain their source id.
            return coachMessages[..<index].last { $0.role == .athlete }?.text
        }.suffix(5).map { $0 }
    }

    mutating func applyCoachIntent(_ intent: CoachIntent, on day: Day) {
        if var currentPlan = plan ?? intent.event.map({ event in
            PlanBuilder().build(.init(goal: .event, startDay: day, endDay: event.day, event: event, availability: .typical))
        }) {
            currentPlan.isActive = true
            plan = WeekReviser().apply(intent, to: currentPlan, today: day).plan
        }
        if let legs = intent.feeling {
            var feedback = feedback(for: day) ?? SubjectiveFeedback(day: day)
            feedback.legs = legs
            setFeedback(feedback)
        }
        if let request = intent.workoutRequest, request.day >= day {
            if workoutRequests == nil { workoutRequests = [:] }
            workoutRequests?[request.day.iso] = request
        }
    }

    /// One local transaction shared by automatic decisions and reviewed chat proposals.
    mutating func acceptPrescription(_ prescription: DailyPrescription, day: Day, ftp: Int?) {
        guard !isWorkoutCompleted(on: day) else { return }
        let previous = today?.day == day ? today : nil
        today = TodayState(day: day, workout: prescription.workout, readiness: prescription.readiness, ai: prescription)
        today?.rideLocation = previous?.rideLocation
        today?.prescriptionFTP = ftp
        attachTodayWorkout(prescription.workout, day: day)
        if let i = plan?.sessions.firstIndex(where: { $0.day == day }), plan?.sessions[i].status == .generated {
            plan?.sessions[i].kind = prescription.workout.kind
            plan?.sessions[i].title = prescription.workout.name
            plan?.sessions[i].targetMinutes = Int((prescription.workout.totalDuration / 60).rounded())
            plan?.sessions[i].targetLoad = prescription.workout.estimatedLoad
            plan?.sessions[i].note = prescription.note.session
        }
        if let i = standaloneSessions?.firstIndex(where: { $0.day == day && $0.status != .completed && $0.status != .skipped }) {
            standaloneSessions?[i].workout = prescription.workout
            standaloneSessions?[i].status = .generated
            standaloneSessions?[i].kind = prescription.workout.kind
            standaloneSessions?[i].title = prescription.workout.name
            standaloneSessions?[i].targetMinutes = Int((prescription.workout.totalDuration / 60).rounded())
            standaloneSessions?[i].targetLoad = prescription.workout.estimatedLoad
            standaloneSessions?[i].prescriptionFTP = ftp
        } else if session(on: day) == nil, prescription.workout.kind != .rest {
            if standaloneSessions == nil { standaloneSessions = [] }
            standaloneSessions?.append(PlannedSession(day: day, kind: prescription.workout.kind, title: prescription.workout.name,
                targetMinutes: Int((prescription.workout.totalDuration / 60).rounded()), targetLoad: prescription.workout.estimatedLoad,
                status: .generated, workout: prescription.workout, location: today?.rideLocation, prescriptionFTP: ftp))
        }
    }

    mutating func setFeedback(_ feedback: SubjectiveFeedback) { feedbackByDay[feedback.day.iso] = feedback }

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

    /// Attaches today's concrete workout to the plan's session for that day, if there is one still open.
    mutating func attachTodayWorkout(_ workout: Workout, day: Day) {
        guard let i = plan?.sessions.firstIndex(where: { $0.day == day }),
              let status = plan?.sessions[i].status, status == .provisional || status == .generated else { return }
        plan?.sessions[i].workout = workout
        plan?.sessions[i].status = .generated
        let ftp = today?.prescriptionFTP ?? workingFTP
        plan?.sessions[i].prescriptionFTP = ftp
    }

    mutating func mergeWellness(_ days: [WellnessDay]) {
        var byDay = Dictionary(uniqueKeysWithValues: wellness.map { ($0.day, $0) })
        for d in days { byDay[d.day] = byDay[d.day].map { $0.merging(d) } ?? d }
        wellness = byDay.values.sorted { $0.day < $1.day }
    }
}
