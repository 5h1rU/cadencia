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

        var isAICoached: Bool { ai != nil }
    }

    struct CoachMessage: Codable, Equatable, Identifiable {
        enum Role: String, Codable { case athlete, coach }
        var id = UUID()
        var role: Role
        var text: String
        var sentAt = Date()
        var intent: CoachIntent?
        var applied = false
    }

    var athlete: AthleteProfile?
    /// FTP the athlete accepted in the app. Falls back to the Intervals value until a review is accepted.
    var acceptedFTP: Int?
    var wellness: [WellnessDay] = []
    var activities: [ActivitySummary] = []
    var powerCurve: [PowerCurvePoint] = []
    var ftpEstimate: FTPEstimate?
    var dismissedFTPProposal: Int?
    var plan: TrainingPlan?
    var today: TodayState?
    var feedbackByDay: [String: SubjectiveFeedback] = [:]
    var ledger = UploadLedger()
    var rideIndex: [RideIndexEntry] = []
    var coachMessages: [CoachMessage] = []
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

    var workingFTP: Int? { acceptedFTP ?? athlete?.workingFTP }

    func feedback(for day: Day) -> SubjectiveFeedback? { feedbackByDay[day.iso] }

    mutating func setFeedback(_ feedback: SubjectiveFeedback) { feedbackByDay[feedback.day.iso] = feedback }

    func wellness(on day: Day) -> WellnessDay? { wellness.first { $0.day == day } }

    /// Attaches today's concrete workout to the plan's session for that day, if there is one still open.
    mutating func attachTodayWorkout(_ workout: Workout, day: Day) {
        guard let i = plan?.sessions.firstIndex(where: { $0.day == day }),
              let status = plan?.sessions[i].status, status == .provisional || status == .generated else { return }
        plan?.sessions[i].workout = workout
        plan?.sessions[i].status = .generated
    }

    mutating func mergeWellness(_ days: [WellnessDay]) {
        var byDay = Dictionary(uniqueKeysWithValues: wellness.map { ($0.day, $0) })
        for d in days { byDay[d.day] = byDay[d.day].map { $0.merging(d) } ?? d }
        wellness = byDay.values.sorted { $0.day < $1.day }
    }
}
