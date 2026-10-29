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
    }

    struct TodayState: Codable, Equatable {
        var day: Day
        var workout: Workout
        var readiness: Readiness
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

    mutating func mergeWellness(_ days: [WellnessDay]) {
        var byDay = Dictionary(uniqueKeysWithValues: wellness.map { ($0.day, $0) })
        for d in days { byDay[d.day] = byDay[d.day].map { $0.merging(d) } ?? d }
        wellness = byDay.values.sorted { $0.day < $1.day }
    }
}
