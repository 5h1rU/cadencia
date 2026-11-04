import Foundation

/// One second of ride data from the trainer and heart-rate strap.
public struct RideSample: Codable, Equatable, Sendable {
    public var time: Date
    public var watts: Int?
    public var heartRate: Int?
    public var cadence: Int?
    public var targetWatts: Int?
    public var speedKmh: Double?
    /// Distance since this ride started, from the trainer's distance counter.
    public var distanceMeters: Double?
    /// Active workout-clock position, independent of scheduler cadence, wall-clock pauses and JSON date precision.
    /// Absent on older recordings; their timestamps and timer events reconstruct the same clock.
    public var workoutElapsed: TimeInterval?

    public init(time: Date, watts: Int? = nil, heartRate: Int? = nil, cadence: Int? = nil, targetWatts: Int? = nil,
                speedKmh: Double? = nil, distanceMeters: Double? = nil, workoutElapsed: TimeInterval? = nil) {
        self.time = time
        self.watts = watts
        self.heartRate = heartRate
        self.cadence = cadence
        self.targetWatts = targetWatts
        self.speedKmh = speedKmh
        self.distanceMeters = distanceMeters
        self.workoutElapsed = workoutElapsed
    }
}

/// Explicit timer transitions distinguish pauses from missing sensor samples in exported rides.
public struct RideTimerEvent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case start, stop }
    public var time: Date
    public var kind: Kind
    public var workoutElapsed: TimeInterval?

    public init(time: Date, kind: Kind, workoutElapsed: TimeInterval? = nil) {
        self.time = time; self.kind = kind; self.workoutElapsed = workoutElapsed
    }
}

/// A completed (or in-progress) indoor ride. Committed locally before anything is uploaded.
public struct RideRecording: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    /// The account the ride belongs to. Never uploaded to a different athlete.
    public var athleteID: String
    public var workout: Workout
    public var plannedSessionID: UUID?
    public var intervalsEventID: Int?
    public var startedAt: Date
    public var endedAt: Date?
    public var samples: [RideSample]
    public var feedback: SubjectiveFeedback?
    /// What Intervals computed once the upload was processed. Nil until fetched.
    public var analysis: ActivityDetail?
    /// The coach's reading of the session, written from `analysis` and the recording. Nil until asked.
    public var debrief: RideDebrief.Report?
    /// The coach note read back from the activity's Notes in Intervals. Nil until synced.
    public var debriefNote: IntervalsActivityNote?
    /// Already recorded by a head unit and imported from Intervals; never queued for upload.
    public var sourceActivity: ActivitySummary?
    public var ftpUsed: Int?
    /// Nil for recordings saved before timer transitions were recorded.
    public var timerEvents: [RideTimerEvent]?
    /// Snapshot of the intended course. Never substitutes for the recorded GPS track.
    public var plannedRoute: GPXRoute?
    public var recordedRoute: GPXRoute?
    public var recordedRouteCheckedAt: Date?

    public init(id: UUID = UUID(), athleteID: String, workout: Workout, plannedSessionID: UUID? = nil, intervalsEventID: Int? = nil,
                startedAt: Date, endedAt: Date? = nil, samples: [RideSample] = [], feedback: SubjectiveFeedback? = nil,
                analysis: ActivityDetail? = nil, debrief: RideDebrief.Report? = nil,
                sourceActivity: ActivitySummary? = nil, ftpUsed: Int? = nil, timerEvents: [RideTimerEvent]? = nil) {
        self.timerEvents = timerEvents
        self.sourceActivity = sourceActivity
        self.ftpUsed = ftpUsed
        self.analysis = analysis
        self.debrief = debrief
        self.id = id
        self.athleteID = athleteID
        self.workout = workout
        self.plannedSessionID = plannedSessionID
        self.intervalsEventID = intervalsEventID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.samples = samples
        self.feedback = feedback
    }

    /// Stable id sent to Intervals as `external_id`, so a lost response can be reconciled instead of re-uploaded.
    public var externalID: String { "cadencia-\(id.uuidString.lowercased())" }

    /// An explicit session link wins over dates and workout ids. The fallback covers older rides
    /// and daily prescriptions recorded before a plan/standalone session was attached.
    public func completes(_ session: PlannedSession) -> Bool {
        guard endedAt != nil else { return false }
        if let plannedSessionID { return plannedSessionID == session.id }
        return Day(startedAt) == session.day &&
            (workout.id == session.workout?.id || workout.id == session.deliveredWorkout?.id)
    }

    public var duration: TimeInterval { (endedAt ?? samples.last?.time ?? startedAt).timeIntervalSince(startedAt) }

    public var averageWatts: Int? { sourceActivity == nil ? average(samples.compactMap(\.watts)) : (analysis?.averageWatts ?? sourceActivity?.averageWatts) }
    public var averageHeartRate: Int? { sourceActivity == nil ? average(samples.compactMap(\.heartRate)) : (analysis?.averageHR ?? sourceActivity?.averageHR) }
    public var averageCadence: Int? { average(samples.compactMap(\.cadence)) }
    public var kilojoules: Double { Double(samples.compactMap(\.watts).reduce(0, +)) / 1000 }

    /// Normalized power: 30 s rolling mean, fourth power, mean, fourth root (Coggan).
    public var normalizedWatts: Int? {
        if let sourceActivity { return analysis?.normalizedWatts ?? sourceActivity.normalizedWatts ?? sourceActivity.averageWatts }
        let watts = samples.map { Double($0.watts ?? 0) }
        guard watts.count >= 30 else { return averageWatts }
        var rolling: [Double] = []
        var sum = watts[0..<30].reduce(0, +)
        rolling.append(sum / 30)
        for i in 30..<watts.count {
            sum += watts[i] - watts[i - 30]
            rolling.append(sum / 30)
        }
        let mean4 = rolling.reduce(0) { $0 + pow($1, 4) } / Double(rolling.count)
        return Int(pow(mean4, 0.25).rounded())
    }

    public func trainingLoad(ftp: Int) -> Int? {
        if let sourceActivity { return analysis?.trainingLoad ?? sourceActivity.trainingLoad }
        guard let np = normalizedWatts, ftp > 0 else { return nil }
        let intensity = Double(np) / Double(ftp)
        return Int((duration / 3600 * intensity * intensity * 100).rounded())
    }

    private func average(_ values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        return Int((Double(values.reduce(0, +)) / Double(values.count)).rounded())
    }
}
