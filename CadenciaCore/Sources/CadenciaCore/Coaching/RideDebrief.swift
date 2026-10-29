import Foundation

/// The coach's post-ride read of a session: what it built, how it was executed block by block, what the
/// heart rate said, and what that means for tomorrow. Written by the AI from the recording plus the
/// analysis Intervals.icu computed once the upload was processed. Everything here is pure; the app
/// decides when to ask, over which network, and where to keep the answer.
public enum RideDebrief {
    // MARK: Brief: everything the coach sees

    public struct Brief: Codable, Equatable, Sendable {
        public struct Session: Codable, Equatable, Sendable {
            public var name: String
            public var kind: String
            public var rationale: String
            public var plannedMinutes: Int
            public var riddenMinutes: Int
        }

        public struct PlannedBlock: Codable, Equatable, Sendable {
            public var index: Int
            public var name: String
            public var minutes: Int
            public var targetWatts: Int
            public var zone: String
            public var isRamp: Bool
        }

        public struct Totals: Codable, Equatable, Sendable {
            public var avgWatts: Int?
            public var normalizedWatts: Int?
            public var load: Int?
            public var avgHeartRate: Int?
            public var avgCadence: Int?
            public var kilojoules: Int
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
            public var hrZoneMinutes: [Int]
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
                    .init(label: $0.label, type: $0.type, startMinute: $0.startSeconds / 60, minutes: Int((Double($0.seconds) / 60).rounded()),
                          avgWatts: $0.averageWatts, normalizedWatts: $0.normalizedWatts, avgHeartRate: $0.averageHR, maxHeartRate: $0.maxHR,
                          avgCadence: $0.averageCadence, decouplingPercent: $0.decoupling.map { ($0 * 10).rounded() / 10 })
                }
            }
        }

        public var locale: String
        public var day: String
        public var session: Session
        public var planned: [PlannedBlock]
        public var executed: [RideCommentary.BlockStats]
        public var totals: Totals
        public var athlete: Athlete
        public var readiness: ReadinessRow?
        public var feedback: Feedback?
        public var context: Context
        public var intervals: Analysis?

        public init(locale: String, ride: RideRecording, ftp: Int, athlete: Athlete? = nil, readiness: Readiness? = nil,
                    plan: TrainingPlan? = nil, recentActivities: [ActivitySummary] = [], analysis: ActivityDetail? = nil) {
            self.locale = locale
            let day = Day(ride.startedAt)
            self.day = day.iso
            let workout = ride.workout
            session = Session(name: workout.name, kind: workout.kind.rawValue, rationale: workout.rationale,
                              plannedMinutes: Int((workout.totalDuration / 60).rounded()), riddenMinutes: Int((ride.duration / 60).rounded()))
            planned = workout.steps.indices.map { i in
                let step = workout.steps[i]
                let mid = step.intensity(at: step.duration / 2)
                return PlannedBlock(index: i, name: step.name, minutes: Int((step.duration / 60).rounded()),
                                    targetWatts: Int((mid * Double(ftp)).rounded()), zone: RideCommentary.Zone.of(intensity: mid).name, isRamp: step.isRamp)
            }
            executed = workout.steps.indices.map { RideCommentary.BlockStats.compute(index: $0, workout: workout, ftp: ftp, samples: ride.samples) }
                .filter { $0.seconds > 0 }
            totals = Totals(avgWatts: ride.averageWatts, normalizedWatts: ride.normalizedWatts, load: ride.trainingLoad(ftp: ftp),
                            avgHeartRate: ride.averageHeartRate, avgCadence: ride.averageCadence, kilojoules: Int(ride.kilojoules.rounded()))
            self.athlete = athlete ?? Athlete(ftp: ftp)
            self.readiness = readiness.map { ReadinessRow(level: $0.level.rawValue, score: $0.score) }
            feedback = ride.feedback.map { Feedback(rpe: $0.rpe, legs: $0.legs?.rawValue) }
            let event = plan?.event.flatMap { $0.day >= day ? $0 : nil }
            context = Context(goal: plan?.goal.rawValue, planTitle: plan?.title, eventName: event?.name,
                              daysToEvent: event.map { day.days(until: $0.day) },
                              recentActivities: recentActivities
                                .filter { $0.day >= day.adding(days: -7) && $0.day <= day && $0.externalID != ride.externalID }
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

        public init(headline: String, grade: Grade, benefit: String, execution: String, physiology: String, next: String,
                    blocks: [BlockVerdict] = [], flags: [String] = [], model: String, createdAt: Date = Date()) {
            self.headline = headline; self.grade = grade; self.benefit = benefit; self.execution = execution
            self.physiology = physiology; self.next = next; self.blocks = blocks; self.flags = flags
            self.model = model; self.createdAt = createdAt
        }
    }

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
        (decoupling, efficiency factor, HR recovery) and recovery. The athlete just finished a trainer session and \
        wants your honest debrief, the way you would talk after the ride: concrete, numeric, warm, never generic.

        You get a JSON brief with the session as prescribed (name, kind, rationale, blocks with target watts and zone), \
        how it was ridden block by block from the trainer (average/max watts, heart rate, cadence, share of time in zone), \
        the ride totals, the athlete's FTP and thresholds, the day's readiness, the athlete's RPE/legs if given, the plan \
        context (goal, next event) and the last week of activities. When present, "intervals" holds what Intervals.icu \
        computed from the file: load, intensity factor, time in power and HR zones, HR recovery, decoupling, efficiency \
        factor, variability index, compliance, fitness/fatigue/form after the ride, and the intervals it detected. \
        Use ONLY these facts. Never invent a number. If something is missing, say what you could not judge.

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
         "blocks": [{"index": int, "verdict": "hit"|"over"|"under"|"short", "note": string (≤ 60 characters)}] one per block that was ridden,
         "flags": [string] (0-3 short items worth watching: HR drift, ended early, power far off target, FTP looks wrong…)}

        Grading: "excellent" when the work blocks were in zone ≥ 85 % of the time and the full duration was ridden; "good" \
        when mostly in zone with minor drift; "partial" when a work block was clearly missed, cut short or ridden far \
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
        let content = try await complete(instructions: RideDebrief.instructions(locale: brief.locale),
                                         userText: try RideDebrief.userMessage(brief))
        do {
            return try RideDebrief.parse(Data(content.utf8), blockCount: brief.planned.count, model: model, now: now)
        } catch {
            throw CompletionError.unusableAnswer
        }
    }
}
