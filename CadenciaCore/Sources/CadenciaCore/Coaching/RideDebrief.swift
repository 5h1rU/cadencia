import Foundation

/// The coach's post-ride read of a session: what it built, how it was executed block by block, what the
/// heart rate said, and what that means for tomorrow. Intervals.icu supplies all completed-ride measurements;
/// the AI explains them alongside the intended workout and athlete context. Everything here is pure; the app
/// decides when to ask, over which network, and where to keep the answer.
public enum RideDebrief {
    public static let evidenceRevision = 2

    /// Earlier reports mixed local block calculations with provider analysis. Refresh them against
    /// the single Intervals analysis source before displaying or syncing their assessment.
    public static func requiresRefresh(_ ride: RideRecording) -> Bool {
        (ride.debrief != nil || ride.debriefNote != nil)
            && ride.debrief?.evidenceRevision != evidenceRevision
    }
    // MARK: Brief: everything the coach sees

    public struct Brief: Codable, Equatable, Sendable {
        public struct Session: Codable, Equatable, Sendable {
            public var name: String
            public var kind: String
            public var rationale: String
            public var plannedMinutes: Int
            public var riddenMinutes: Int?
        }

        public struct PlannedBlock: Codable, Equatable, Sendable {
            public var index: Int
            public var name: String
            public var minutes: Int
            public var targetWatts: Int
            public var zone: String
            public var isRamp: Bool
            public var startSeconds: Double
            public var seconds: Double
        }

        public struct Athlete: Codable, Equatable, Sendable {
            public var ftp: Int
            public var weightKg: Double?
            public var maxHR: Int?
            public var lthr: Int?
        }

        public struct ReadinessRow: Codable, Equatable, Sendable {
            public var level: String
            public var score: Int
        }

        public struct Feedback: Codable, Equatable, Sendable {
            public var rpe: Int?
            public var legs: String?
        }

        public struct Context: Codable, Equatable, Sendable {
            public var goal: String?
            public var planTitle: String?
            public var eventName: String?
            public var daysToEvent: Int?
            public var recentActivities: [CoachBrief.ActivityRow]
        }

        /// Intervals' numbers, rounded to what a coach quotes. Zone times in minutes so the model does not do arithmetic.
        public struct Analysis: Codable, Equatable, Sendable {
            public struct ZoneMinutes: Codable, Equatable, Sendable { public var zone: String; public var minutes: Int }
            public struct Interval: Codable, Equatable, Sendable {
                public var label: String?
                public var type: String?
                public var startMinute: Int
                public var minutes: Int
                public var startSeconds: Int
                public var seconds: Int
                public var avgWatts: Int?
                public var normalizedWatts: Int?
                public var avgHeartRate: Int?
                public var maxHeartRate: Int?
                public var avgCadence: Int?
                public var decouplingPercent: Double?
            }

            public var trainingLoad: Int?
            public var intensityFactor: Double?
            public var normalizedWatts: Int?
            public var avgWatts: Int?
            public var avgHeartRate: Int?
            public var maxHeartRate: Int?
            public var ftpUsed: Int?
            public var estimatedFTP: Int?
            public var kilojoules: Int?
            public var kilojoulesAboveFTP: Int?
            public var powerZoneMinutes: [ZoneMinutes]
            public var powerZoneSeconds: [ActivityDetail.ZoneTime]
            public var hrZoneMinutes: [Int]
            public var hrZoneSeconds: [Int]
            public var hrRecoveryDrop: Int?
            public var decouplingPercent: Double?
            public var efficiencyFactor: Double?
            public var variabilityIndex: Double?
            public var compliancePercent: Double?
            public var fitnessCTL: Double?
            public var fatigueATL: Double?
            public var formTSB: Double?
            public var intervals: [Interval]

            public init(_ d: ActivityDetail) {
                trainingLoad = d.trainingLoad
                intensityFactor = d.intensityFactor.map { ($0 * 100).rounded() / 100 }
                normalizedWatts = d.normalizedWatts
                avgWatts = d.averageWatts
                avgHeartRate = d.averageHR
                maxHeartRate = d.maxHR
                ftpUsed = d.ftp
                estimatedFTP = d.estimatedFTP
                kilojoules = d.kilojoules
                kilojoulesAboveFTP = d.kilojoulesAboveFTP
                powerZoneSeconds = d.powerZoneTimes
                hrZoneSeconds = d.hrZoneTimes
                powerZoneMinutes = d.powerZoneTimes.map { .init(zone: $0.zone, minutes: Int((Double($0.seconds) / 60).rounded())) }
                hrZoneMinutes = d.hrZoneTimes.map { Int((Double($0) / 60).rounded()) }
                hrRecoveryDrop = d.hrRecovery?.drop
                decouplingPercent = d.decoupling.map { ($0 * 10).rounded() / 10 }
                efficiencyFactor = d.efficiencyFactor.map { ($0 * 100).rounded() / 100 }
                variabilityIndex = d.variabilityIndex.map { ($0 * 100).rounded() / 100 }
                compliancePercent = d.compliance.map { $0.rounded() }
                fitnessCTL = d.ctl.map { $0.rounded() }
                fatigueATL = d.atl.map { $0.rounded() }
                formTSB = d.tsb.map { $0.rounded() }
                intervals = d.intervals.map {
                    .init(label: $0.label, type: $0.type, startMinute: $0.startSeconds / 60, minutes: Int((Double($0.seconds) / 60).rounded()), startSeconds: $0.startSeconds, seconds: $0.seconds,
                          avgWatts: $0.averageWatts, normalizedWatts: $0.normalizedWatts, avgHeartRate: $0.averageHR, maxHeartRate: $0.maxHR,
                          avgCadence: $0.averageCadence, decouplingPercent: $0.decoupling.map { ($0 * 10).rounded() / 10 })
                }
            }
        }

        public var locale: String
        public var day: String
        public var session: Session
        public var planned: [PlannedBlock]
        public var analysisSource: String
        public var athlete: Athlete
        public var readiness: ReadinessRow?
        public var feedback: Feedback?
        public var context: Context
        public var intervals: Analysis?
        public var unstructuredRide: Bool?
        public var recordedDistanceKm: Double?
        public var recordedCourse: CoachBrief.Event.Course?
        public var isReanalysis: Bool?

        public init(locale: String, ride: RideRecording, ftp: Int, athlete: Athlete? = nil, readiness: Readiness? = nil,
                    plan: TrainingPlan? = nil, recentActivities: [ActivitySummary] = [], analysis: ActivityDetail? = nil) {
            self.locale = locale
            let analysis = analysis.flatMap { $0.analyzed ? $0 : nil }
            analysisSource = "intervals.icu"
            let day = Day(ride.startedAt)
            self.day = day.iso
            let workout = ride.workout
            let unstructured = ride.sourceActivity != nil && ride.plannedSessionID == nil
            unstructuredRide = unstructured
            recordedDistanceKm = ride.recordedRoute?.distanceKm
            recordedCourse = ride.recordedRoute.map { CoachBrief.Event.Course(EventCourse(elevationGainM: $0.elevationGainM,
                elevationLossM: $0.elevationLossM, startAltitudeM: $0.start?.elevationM, minAltitudeM: $0.minAltitudeM, maxAltitudeM: $0.maxAltitudeM, route: $0)) }
            session = Session(name: workout.name, kind: unstructured ? "unstructured" : workout.kind.rawValue, rationale: workout.rationale,
                              plannedMinutes: Int((workout.totalDuration / 60).rounded()), riddenMinutes: analysis.map { Int(($0.movingTime / 60).rounded()) })
            planned = workout.steps.indices.map { i in
                let step = workout.steps[i]
                let mid = step.intensity(at: step.duration / 2)
                return PlannedBlock(index: i, name: step.name, minutes: Int((step.duration / 60).rounded()),
                                    targetWatts: Int((mid * Double(ftp)).rounded()), zone: RideCommentary.Zone.of(intensity: mid).name, isRamp: step.isRamp,
                                    startSeconds: workout.steps[..<i].reduce(0) { $0 + $1.duration }, seconds: step.duration)
            }
            isReanalysis = RideDebrief.requiresRefresh(ride)
            self.athlete = athlete ?? Athlete(ftp: ftp)
            self.readiness = readiness.map { ReadinessRow(level: $0.level.rawValue, score: $0.score) }
            feedback = ride.feedback.map { Feedback(rpe: $0.rpe, legs: $0.legs?.rawValue) }
            let event = plan?.event.flatMap { $0.day >= day ? $0 : nil }
            context = Context(goal: plan?.goal.rawValue, planTitle: plan?.title, eventName: event?.name,
                              daysToEvent: event.map { day.days(until: $0.day) },
                              recentActivities: recentActivities
                                .filter { $0.day >= day.adding(days: -7) && $0.day <= day && $0.externalID != ride.externalID && $0.id != ride.sourceActivity?.id }
                                .sorted { $0.startDateLocal < $1.startDateLocal }
                                .map(CoachBrief.ActivityRow.init))
            intervals = analysis.map(Analysis.init)
        }
    }

    // MARK: Report: what the coach answers

    public struct Report: Codable, Equatable, Sendable {
        /// How close the session came to what was prescribed.
        public enum Grade: String, Codable, CaseIterable, Sendable { case excellent, good, partial, off }

        public struct BlockVerdict: Codable, Equatable, Sendable, Identifiable {
            public enum Verdict: String, Codable, CaseIterable, Sendable { case hit, over, under, short }
            public var index: Int
            public var verdict: Verdict
            public var note: String
            public var id: Int { index }
            public init(index: Int, verdict: Verdict, note: String) { self.index = index; self.verdict = verdict; self.note = note }
        }

        public var headline: String
        public var grade: Grade
        public var benefit: String
        public var execution: String
        public var physiology: String
        public var next: String
        public var blocks: [BlockVerdict]
        public var flags: [String]
        public var model: String
        public var createdAt: Date
        public var evidenceRevision: Int?
        public var correctionNotice: String?

        /// Human-readable Notes in Intervals, also used by session details after syncing.
        public var noteContent: String {
            let paragraphs = [correctionNotice ?? "", headline, benefit, execution, physiology, next].filter { !$0.isEmpty }
            let blockNotes = blocks.filter { !$0.note.isEmpty }.map { "\($0.index + 1). \($0.note)" }
            let watch = flags.map { "• \($0)" }
            return IntervalsActivityNote.coachPrefix +
                (paragraphs + [blockNotes.joined(separator: "\n"), watch.joined(separator: "\n")].filter { !$0.isEmpty })
                .joined(separator: "\n\n")
        }

        public init(headline: String, grade: Grade, benefit: String, execution: String, physiology: String, next: String,
                    blocks: [BlockVerdict] = [], flags: [String] = [], model: String, createdAt: Date = Date(),
                    evidenceRevision: Int? = RideDebrief.evidenceRevision, correctionNotice: String? = nil) {
            self.headline = headline; self.grade = grade; self.benefit = benefit; self.execution = execution
            self.physiology = physiology; self.next = next; self.blocks = blocks; self.flags = flags
            self.model = model; self.createdAt = createdAt
            self.evidenceRevision = evidenceRevision; self.correctionNotice = correctionNotice
        }
    }

    public enum AnalysisError: Error, Equatable, Sendable { case notReady }

    public enum ParseError: Error, Equatable, Sendable { case noHeadline, unknownGrade(String) }

    /// Accepts the model's JSON. The headline and grade are mandatory; prose fields default to empty, block
    /// verdicts outside the workout are dropped, and an unknown block verdict is treated as `hit` with its note kept.
    public static func parse(_ data: Data, blockCount: Int, model: String, now: Date = Date()) throws -> Report {
        struct WireBlock: Decodable { var index: Int?; var verdict: String?; var note: String? }
        struct Wire: Decodable {
            var headline: String?; var grade: String?; var benefit: String?; var execution: String?
            var physiology: String?; var next: String?; var blocks: [WireBlock]?; var flags: [String]?
        }
        let w = try JSONDecoder().decode(Wire.self, from: data)
        func clean(_ s: String?) -> String { s?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        let headline = clean(w.headline)
        guard !headline.isEmpty else { throw ParseError.noHeadline }
        let gradeText = clean(w.grade).lowercased()
        guard let grade = Report.Grade(rawValue: gradeText) else { throw ParseError.unknownGrade(gradeText) }
        let blocks = (w.blocks ?? []).compactMap { b -> Report.BlockVerdict? in
            guard let i = b.index, (0..<blockCount).contains(i) else { return nil }
            return .init(index: i, verdict: b.verdict.flatMap { Report.BlockVerdict.Verdict(rawValue: $0.lowercased()) } ?? .hit, note: clean(b.note))
        }
        return Report(headline: headline, grade: grade, benefit: clean(w.benefit), execution: clean(w.execution),
                      physiology: clean(w.physiology), next: clean(w.next), blocks: blocks,
                      flags: (w.flags ?? []).map(clean).filter { !$0.isEmpty }, model: model, createdAt: now)
    }

    // MARK: Prompt

    public static func instructions(locale: String) -> String {
        """
        You are the head coach inside Cadencia, a cycling training app: an expert road-cycling coach with deep knowledge \
        of exercise physiology, power-based training (FTP, zones, NP, IF, TSS/CTL/ATL/TSB), heart-rate response \
        (decoupling, efficiency factor, HR recovery) and recovery. The athlete just finished a cycling session and \
        wants your honest debrief, the way you would talk after the ride: concrete, numeric, warm, never generic.

        All completed-ride measurements come from Intervals.icu after processing the uploaded activity, \
        whether the ride was recorded by this phone or an outdoor head unit. Missing measurements are unknown, \
        not zero effort. Never invent per-block power, compliance or cadence.

        When unstructuredRide is true, there was no planned prescription. Assess the actual training stimulus and recovery \
        using recorded evidence; never invent target blocks or grade the rider against an endurance workout they did not plan. \
        Use recordedCourse for climb and altitude context when available; it describes actual GPS, not the intended course.

        You get the intended session (planned blocks, target watts, start and duration in seconds), athlete and plan context, \
        and `intervals`: the completed activity's provider analysis. Only `intervals` contains measured performance: \
        load, intensity, power/HR zones, HR recovery, decoupling, efficiency, compliance, fitness/fatigue and detected intervals. \
        Zone seconds and interval start/duration seconds preserve short efforts; rounded minutes are for readable summaries. \
        The language model explains these results; it does not recompute performance from phone samples.

        A whole-ride average or one combined RECOVERY interval cannot establish that a short planned effort was missed. \
        Assess a specific planned block only when Intervals supplies a detected interval with compatible timing and duration. \
        Otherwise explain what the aggregate zones and compliance support and state that individual-block detail is unavailable. \
        Do not fabricate a block average, map a whole-ride interval to a short effort, or lower the grade solely because \
        Intervals did not separate the efforts. High overall compliance supports overall adherence, not invented per-block certainty. \
        Use only provided facts; missing data means an assessment limit. When isReanalysis is true, assess this provider \
        evidence afresh without repeating an earlier verdict.

        Write in the language with code "\(locale)", in the second person. Answer ONLY with a JSON object:
        {"headline": string (one sentence verdict, ≤ 120 characters),
         "grade": "excellent"|"good"|"partial"|"off",
         "benefit": string (2-3 sentences: what this session trained physiologically and whether it delivered that stimulus, \
        tied to the time in the intended zone and the load),
         "execution": string (2-4 sentences: how it was ridden against the prescription, naming blocks and watts; \
        over-riding counts against execution as much as under-riding),
         "physiology": string (2-3 sentences: what heart rate, decoupling, efficiency factor, HR recovery and cadence say \
        about aerobic condition and fatigue today; compare to the athlete's thresholds when given),
         "next": string (1-2 sentences: what this means for recovery and the next session, consistent with the plan context),
         "blocks": [{"index": int, "verdict": "hit"|"over"|"under"|"short", "note": string (≤ 60 characters)}] only for planned blocks supported by corresponding Intervals measurements; otherwise [],
         "flags": [string] (0-3 short items worth watching: HR drift, ended early, power far off target, FTP looks wrong…)}

        For unstructured rides, grade only what recorded effort and physiology support and say that prescription adherence cannot be assessed. \
        For prescribed sessions: "excellent" when Intervals compliance, zone times and duration support full delivery; "good" \
        when the provider evidence supports the purpose with minor drift; "partial" when a work block was clearly missed, cut short or ridden far \
        off target; "off" when the session was abandoned early or ridden as a different workout. Warm-up and cool-down \
        never lower the grade. A block "short" means it ended early; "over"/"under" mean average power out of the zone.
        """
    }

    public static func userMessage(_ brief: Brief) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(brief), as: UTF8.self)
    }
}

public extension LLMCoach {
    /// The coach's debrief of a finished ride. Throws like `complete`; the app decides whether to retry.
    func debrief(_ brief: RideDebrief.Brief, now: Date = Date()) async throws -> RideDebrief.Report {
        guard brief.intervals != nil else { throw RideDebrief.AnalysisError.notReady }
        let content = try await complete(instructions: RideDebrief.instructions(locale: brief.locale),
                                         userText: try RideDebrief.userMessage(brief))
        do {
            return try RideDebrief.parse(Data(content.utf8), blockCount: brief.planned.count, model: model, now: now)
        } catch {
            throw CompletionError.unusableAnswer
        }
    }
}
