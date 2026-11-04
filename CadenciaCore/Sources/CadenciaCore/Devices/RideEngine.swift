import Foundation

/// Drives a structured workout second by second: which step we are in, what the trainer should target,
/// and the recorded samples. Pure state; the app feeds it a clock tick and device readings.
public struct RideEngine: Equatable, Sendable {
    public enum State: String, Sendable { case ready, riding, paused, finished }

    public private(set) var recording: RideRecording
    public private(set) var state: State = .ready
    public private(set) var elapsed: TimeInterval = 0
    /// Asks the athlete to pause after five seconds of confirmed inactivity; never pauses automatically.
    public private(set) var shouldSuggestPause = false
    /// Manual intensity adjustment, 0.8…1.2. Never lifts the target above the workout ceiling.
    public var intensityScale: Double = 1.0
    public let ftp: Int

    private var lastTick: Date?
    private var stoppedPedalingAt: Date?
    private var pauseSuggestionDismissed = false
    private var lastTrainerDistanceMeters: Int?
    private var distanceMeters: Double?

    public init(recording: RideRecording, ftp: Int) {
        self.recording = recording
        self.recording.ftpUsed = recording.ftpUsed ?? ftp
        self.ftp = ftp
    }

    public var workout: Workout { recording.workout }

    public var currentStepIndex: Int? {
        var t = elapsed
        for (i, step) in workout.steps.enumerated() {
            if t < step.duration { return i }
            t -= step.duration
        }
        return nil
    }

    public var currentStep: WorkoutStep? { currentStepIndex.map { workout.steps[$0] } }

    public var elapsedInStep: TimeInterval {
        var t = elapsed
        for step in workout.steps {
            if t < step.duration { return t }
            t -= step.duration
        }
        return 0
    }

    public var remainingInStep: TimeInterval { (currentStep?.duration ?? 0) - elapsedInStep }
    public var remainingTotal: TimeInterval { max(workout.totalDuration - elapsed, 0) }
    public var progress: Double { workout.totalDuration > 0 ? min(elapsed / workout.totalDuration, 1) : 1 }

    /// Watts the trainer should hold right now (ERG), after the manual scale and the session ceiling.
    public var targetWatts: Int? {
        guard let step = currentStep else { return nil }
        var intensity = step.intensity(at: elapsedInStep) * intensityScale
        if let ceiling = workout.intensityCeiling { intensity = min(intensity, ceiling) }
        return Int((intensity * Double(ftp)).rounded())
    }

    public var ceilingWatts: Int? { workout.intensityCeiling.map { Int(($0 * Double(ftp)).rounded()) } }

    public mutating func start(at now: Date, trainerDistanceMeters: Int? = nil) {
        guard state == .ready || state == .paused else { return }
        state = .riding
        lastTick = now
        resetPauseSuggestion()
        // Reset the baseline on resume, excluding any movement while paused.
        lastTrainerDistanceMeters = trainerDistanceMeters
        if trainerDistanceMeters != nil, distanceMeters == nil { distanceMeters = 0 }
        if recording.timerEvents == nil { recording.timerEvents = [] }
        recording.timerEvents?.append(RideTimerEvent(time: now, kind: .start, workoutElapsed: elapsed))
    }

    public mutating func pause(at now: Date? = nil) {
        guard state == .riding else { return }
        let stoppedAt = now ?? lastTick ?? recording.startedAt
        if let lastTick { elapsed += max(0, stoppedAt.timeIntervalSince(lastTick)) }
        recording.timerEvents?.append(RideTimerEvent(time: stoppedAt, kind: .stop, workoutElapsed: elapsed))
        state = .paused
        lastTick = nil
        resetPauseSuggestion()
    }

    /// "Keep riding" suppresses further prompts until pedaling resumes or the ride is paused.
    public mutating func dismissPauseSuggestion() {
        shouldSuggestPause = false
        pauseSuggestionDismissed = true
    }

    /// Called about once per second with fresh readings (nil for missing/stale data).
    /// Returns the sample recorded, if riding.
    @discardableResult
    public mutating func tick(now: Date, watts: Int?, heartRate: Int?, cadence: Int?,
                              speedKmh: Double? = nil, trainerDistanceMeters: Int? = nil) -> RideSample? {
        guard state == .riding else { return nil }
        if let last = lastTick { elapsed += now.timeIntervalSince(last) }
        lastTick = now
        if let total = trainerDistanceMeters, total >= 0 {
            if let previous = lastTrainerDistanceMeters {
                // A trainer reset/reconnect starts a new counter segment without losing prior distance.
                distanceMeters = (distanceMeters ?? 0) + Double(max(0, total - previous))
            } else if distanceMeters == nil { distanceMeters = 0 }
            lastTrainerDistanceMeters = total
        }
        let sample = RideSample(time: now, watts: watts, heartRate: heartRate, cadence: cadence, targetWatts: targetWatts,
                                speedKmh: speedKmh, distanceMeters: trainerDistanceMeters == nil ? nil : distanceMeters,
                                workoutElapsed: elapsed)
        recording.samples.append(sample)
        if elapsed >= workout.totalDuration {
            finish(at: now)
        } else {
            updatePauseSuggestion(now: now, watts: watts, cadence: cadence)
        }
        return sample
    }

    public mutating func finish(at now: Date) {
        guard state != .finished else { return }
        if state == .riding {
            if let lastTick { elapsed += max(0, now.timeIntervalSince(lastTick)) }
            recording.timerEvents?.append(RideTimerEvent(time: now, kind: .stop, workoutElapsed: elapsed))
        }
        state = .finished
        recording.endedAt = now
        lastTick = nil
        resetPauseSuggestion()
    }

    private mutating func updatePauseSuggestion(now: Date, watts: Int?, cadence: Int?) {
        // Cadence detects stopped cranks even while the flywheel is still producing power.
        // Power is the fallback for trainers without cadence; missing data is never inactivity.
        guard let pedaling = cadence.map({ $0 > 0 }) ?? watts.map({ $0 > 0 }) else {
            stoppedPedalingAt = nil
            shouldSuggestPause = false
            return
        }
        if pedaling {
            resetPauseSuggestion()
        } else {
            let stoppedAt = stoppedPedalingAt ?? now
            stoppedPedalingAt = stoppedAt
            shouldSuggestPause = !pauseSuggestionDismissed && now.timeIntervalSince(stoppedAt) >= 5
        }
    }

    private mutating func resetPauseSuggestion() {
        stoppedPedalingAt = nil
        shouldSuggestPause = false
        pauseSuggestionDismissed = false
    }

    public mutating func adjustIntensity(by delta: Double) {
        intensityScale = min(max(intensityScale + delta, 0.8), 1.2)
    }
}
