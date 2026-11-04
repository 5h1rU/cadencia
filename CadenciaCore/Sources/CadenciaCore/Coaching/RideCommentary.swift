import Foundation

/// The coach's voice during a ride: short, spoken lines at the moments that matter (a block starting,
/// the middle of a long block, the finish), written by the AI from what the sensors just recorded.
/// Everything here is pure: the app decides the clock, the network and the loudspeaker.
public enum RideCommentary {
    /// When the coach may speak. One cue per moment per ride; the scheduler guarantees it.
    public enum Moment: Equatable, Hashable, Sendable {
        case blockStart(Int)
        case midBlock(Int)
        case finish

        public var wire: String {
            switch self {
            case .blockStart: return "block_start"
            case .midBlock: return "mid_block"
            case .finish: return "finish"
            }
        }
    }

    /// Decides when a cue is due. Block starts wait a few seconds so the trainer has settled and the
    /// previous block's numbers are complete; mid-block cues only exist for blocks of eight minutes or more.
    public struct Scheduler: Equatable, Sendable {
        public static let settleSeconds: TimeInterval = 8
        public static let midBlockMinimum: TimeInterval = 8 * 60

        private var fired: Set<Moment> = []

        public init() {}

        public mutating func due(stepIndex: Int?, elapsedInStep: TimeInterval, stepDuration: TimeInterval, finished: Bool) -> Moment? {
            if finished { return claim(.finish) }
            guard let i = stepIndex else { return nil }
            if elapsedInStep >= Self.settleSeconds, !fired.contains(.blockStart(i)) { return claim(.blockStart(i)) }
            if stepDuration >= Self.midBlockMinimum, elapsedInStep >= stepDuration / 2, !fired.contains(.midBlock(i)) { return claim(.midBlock(i)) }
            return nil
        }

        private mutating func claim(_ moment: Moment) -> Moment? {
            fired.insert(moment).inserted ? moment : nil
        }
    }

    /// How far from the target a second still counts as "in zone": ±10 % (72–88 W on an 80 W target).
    public static let zoneTolerance = 0.10

    /// What one block of the ride looked like, from the recorded samples.
    public struct BlockStats: Codable, Equatable, Sendable {
        public var index: Int
        public var name: String
        public var seconds: Int
        public var targetWatts: Int?
        public var avgWatts: Int?
        public var maxWatts: Int?
        public var avgHeartRate: Int?
        public var maxHeartRate: Int?
        public var avgCadence: Int?
        /// Share of observed riding time within `zoneTolerance` of its recorded target, 0–100.
        public var inZonePercent: Int?

        /// Fraction of the ridden block backed by fresh power observations. Missing data is unknown, never failure.
        public var powerCoveragePercent: Int?
        /// Time-weighted target actually sent to the trainer, including manual intensity changes.
        public var recordedTargetWatts: Int?

        public static func compute(index: Int, workout: Workout, ftp: Int, samples: [RideSample], upTo elapsed: TimeInterval? = nil,
                                   startedAt: Date? = nil, timerEvents: [RideTimerEvent]? = nil, endedAt: Date? = nil) -> BlockStats {
            let timeline = RideTimeline(samples: samples, startedAt: startedAt, timerEvents: timerEvents, endedAt: endedAt)
            return compute(index: index, workout: workout, ftp: ftp, timeline: timeline, upTo: elapsed)
        }

        public static func compute(index: Int, workout: Workout, ftp: Int, timeline: RideTimeline, upTo elapsed: TimeInterval? = nil) -> BlockStats {
            let step = workout.steps[index]
            let start = workout.steps[..<index].reduce(0) { $0 + $1.duration }
            let end = max(start, min(elapsed ?? .infinity, timeline.duration, start + step.duration))
            let selected = timeline.observations.compactMap { observation -> (RideSample, Double)? in
                let seconds = min(end, observation.end) - max(start, observation.start)
                return seconds > 0 ? (observation.sample, seconds) : nil
            }
            func average(_ key: KeyPath<RideSample, Int?>) -> Int? {
                let values = selected.compactMap { sample, seconds in sample[keyPath: key].map { (Double($0), seconds) } }
                let duration = values.reduce(0) { $0 + $1.1 }
                return duration > 0 ? Int((values.reduce(0) { $0 + $1.0 * $1.1 } / duration).rounded()) : nil
            }
            let judged = selected.compactMap { sample, seconds -> (Bool, Double)? in
                guard let watts = sample.watts, let target = sample.targetWatts, target > 0 else { return nil }
                return (abs(Double(watts) / Double(target) - 1) <= RideCommentary.zoneTolerance, seconds)
            }
            let judgedSeconds = judged.reduce(0) { $0 + $1.1 }
            let powerSeconds = selected.filter { $0.0.watts != nil }.reduce(0) { $0 + $1.1 }
            let duration = end - start
            let midpoint = min(step.intensity(at: step.duration / 2), workout.intensityCeiling ?? .infinity)
            return BlockStats(index: index, name: step.name, seconds: Int(duration.rounded()),
                              targetWatts: Int((midpoint * Double(ftp)).rounded()), avgWatts: average(\.watts),
                              maxWatts: selected.compactMap { $0.0.watts }.max(), avgHeartRate: average(\.heartRate),
                              maxHeartRate: selected.compactMap { $0.0.heartRate }.max(), avgCadence: average(\.cadence),
                              inZonePercent: judgedSeconds > 0 ? Int((judged.filter { $0.0 }.reduce(0) { $0 + $1.1 } / judgedSeconds * 100).rounded()) : nil,
                              powerCoveragePercent: duration > 0 ? Int((powerSeconds / duration * 100).rounded()) : nil,
                              recordedTargetWatts: average(\.targetWatts))
        }
    }

    /// Coggan-style zone of a fraction of FTP, with what training there does. Given to the model so a
    /// line like "this is where your aerobic engine grows" is grounded in the actual target.
    public struct Zone: Codable, Equatable, Sendable {
        public var name: String
        public var adaptation: String

        public static func of(intensity: Double) -> Zone {
            switch intensity {
            case ..<0.55: return Zone(name: "Z1 recovery", adaptation: "blood flow and recovery; no training stress")
            case ..<0.76: return Zone(name: "Z2 endurance", adaptation: "mitochondrial density, fat oxidation, aerobic base")
            case ..<0.91: return Zone(name: "Z3 tempo", adaptation: "muscular endurance and sustained aerobic power")
            case ..<1.06: return Zone(name: "Z4 threshold", adaptation: "lactate clearance and FTP")
            case ..<1.21: return Zone(name: "Z5 VO2max", adaptation: "maximal oxygen uptake and cardiac output")
            default: return Zone(name: "Z6 anaerobic", adaptation: "anaerobic capacity and neuromuscular power")
            }
        }
    }

    /// The facts behind one cue. Compact: the model gets numbers, not sample streams.
    public struct Brief: Codable, Equatable, Sendable {
        public struct Block: Codable, Equatable, Sendable {
            public var index: Int
            public var name: String
            public var minutes: Int
            public var targetWatts: Int
            public var zone: Zone
            public var isRamp: Bool
        }

        public var locale: String
        public var moment: String
        public var workoutName: String
        public var kind: String
        public var rationale: String
        public var ftp: Int
        public var totalBlocks: Int
        public var elapsedMinutes: Int
        public var remainingMinutes: Int
        public var intensityPercent: Int
        public var previousBlock: BlockStats?
        public var currentBlock: Block?
        public var currentSoFar: BlockStats?
        public var nextBlock: Block?
        public var liveHeartRate: Int?
        public var liveCadence: Int?
        public var rideSoFar: BlockStats?

        public init(locale: String, moment: Moment, workout: Workout, ftp: Int, stepIndex: Int?, elapsed: TimeInterval,
                    intensityScale: Double, samples: [RideSample], liveHeartRate: Int? = nil, liveCadence: Int? = nil,
                    startedAt: Date? = nil, timerEvents: [RideTimerEvent]? = nil) {
            self.locale = locale
            self.moment = moment.wire
            self.workoutName = workout.name
            self.kind = workout.kind.rawValue
            self.rationale = workout.rationale
            self.ftp = ftp
            self.totalBlocks = workout.steps.count
            self.elapsedMinutes = Int(elapsed / 60)
            self.remainingMinutes = Int(max(workout.totalDuration - elapsed, 0) / 60)
            self.intensityPercent = Int((intensityScale * 100).rounded())
            self.liveHeartRate = liveHeartRate
            self.liveCadence = liveCadence

            let timeline = RideTimeline(samples: samples, startedAt: startedAt, timerEvents: timerEvents)
            func block(_ i: Int) -> Block? {
                guard workout.steps.indices.contains(i) else { return nil }
                let step = workout.steps[i]
                let mid = step.intensity(at: step.duration / 2) * intensityScale
                return Block(index: i, name: step.name, minutes: Int((step.duration / 60).rounded()),
                             targetWatts: Int((mid * Double(ftp)).rounded()), zone: Zone.of(intensity: mid), isRamp: step.isRamp)
            }
            if case .finish = moment {
                if let last = workout.steps.indices.last {
                    previousBlock = BlockStats.compute(index: last, workout: workout, ftp: ftp, timeline: timeline)
                }
            } else if let i = stepIndex {
                currentBlock = block(i)
                nextBlock = block(i + 1)
                if i > 0 { previousBlock = BlockStats.compute(index: i - 1, workout: workout, ftp: ftp, timeline: timeline) }
                if case .midBlock = moment { currentSoFar = BlockStats.compute(index: i, workout: workout, ftp: ftp, timeline: timeline, upTo: elapsed) }
            }
            if !samples.isEmpty {
                let whole = Workout(name: workout.name, kind: workout.kind, steps: [WorkoutStep(name: "ride", duration: workout.totalDuration, intensity: 0)])
                var all = BlockStats.compute(index: 0, workout: whole, ftp: ftp, timeline: timeline, upTo: elapsed)
                all.targetWatts = nil
                rideSoFar = all
            }
        }
    }

    /// What the model answers: one spoken line and the tone it should be delivered in.
    public struct Line: Codable, Equatable, Sendable {
        public enum Mood: String, Codable, CaseIterable, Sendable { case praise, steady, push, caution, calm }
        public var caption: String
        public var mood: Mood

        public init(caption: String, mood: Mood) {
            self.caption = caption
            self.mood = mood
        }
    }

    public static let maxCaptionLength = 180

    public enum ParseError: Error, Equatable { case noCaption }

    /// Accepts `{"caption": "...", "mood": "..."}`; an unknown mood is `steady`, an empty caption is an error,
    /// and anything longer than one breath is cut at a sentence boundary so the voice never drones.
    public static func parse(_ data: Data) throws -> Line {
        struct Wire: Decodable { var caption: String?; var mood: String? }
        let w = try JSONDecoder().decode(Wire.self, from: data)
        var caption = (w.caption ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !caption.isEmpty else { throw ParseError.noCaption }
        if caption.count > maxCaptionLength {
            let head = String(caption.prefix(maxCaptionLength))
            if let cut = head.lastIndex(where: { ".!?".contains($0) }) { caption = String(head[...cut]) }
            else { caption = head.trimmingCharacters(in: .whitespaces) + "…" }
        }
        return Line(caption: caption, mood: w.mood.flatMap(Line.Mood.init(rawValue:)) ?? .steady)
    }

    /// Who the voice is. Spoken out loud through the phone, so lines must be short, concrete and said once.
    public static func instructions(locale: String) -> String {
        """
        You are the athlete's cycling coach riding alongside them on the trainer, speaking through the phone's \
        loudspeaker. Speak in the language with code "\(locale)", in the second person, like a calm, experienced \
        road-cycling coach who likes numbers: name what the sensors show and what it means physiologically.

        You get a JSON brief with the moment (block_start, mid_block, finish), the workout, FTP, the block that just \
        ended (average and max watts, heart rate, cadence, share of time in zone), the block starting (target watts, \
        minutes, zone and what that zone trains) and the next one. Use ONLY those facts; never invent numbers.

        Rules:
        - One or two short sentences, at most \(maxCaptionLength) characters, no emoji, no lists, no greetings beyond the first block.
        - block_start: say what the block just done looked like in one clause if there was one (praise if inZonePercent ≥ 80, \
        a concrete correction if below), then what is coming and why it matters (the zone's adaptation), with the target watts.
        - mid_block: one line of encouragement tied to a real number (watts held, heart rate, time left in the block).
        - finish: sum the ride in one sentence with its average watts and what it built; be warm.
        - mood: "praise" when the numbers were good, "push" to ask for a little more, "caution" when power is far over target \
        or heart rate is high for the zone, "calm" for recovery and cool-down, otherwise "steady".
        - Never tell the athlete to exceed the plan; corrections only bring them back to the target.

        Answer ONLY with a JSON object: {"caption": string, "mood": "praise"|"steady"|"push"|"caution"|"calm"}.
        """
    }

    public static func userMessage(_ brief: Brief) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(brief), as: UTF8.self)
    }
}

public extension LLMCoach {
    /// One spoken line for a moment of the ride. Throws like `complete`; the app decides whether to retry.
    func comment(_ brief: RideCommentary.Brief) async throws -> RideCommentary.Line {
        let content = try await complete(instructions: RideCommentary.instructions(locale: brief.locale),
                                         userText: try RideCommentary.userMessage(brief))
        return try RideCommentary.parse(Data(content.utf8))
    }
}
