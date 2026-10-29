import Foundation

/// Drives a structured workout second by second: which step we are in, what the trainer should target,
/// and the recorded samples. Pure state; the app feeds it a clock tick and device readings.
public struct RideEngine: Equatable, Sendable {
    public enum State: String, Sendable { case ready, riding, paused, finished }

    public private(set) var recording: RideRecording
    public private(set) var state: State = .ready
    public private(set) var elapsed: TimeInterval = 0
    /// Manual intensity adjustment, 0.8…1.2. Never lifts the target above the workout ceiling.
    public var intensityScale: Double = 1.0
    public let ftp: Int

    private var lastTick: Date?

    public init(recording: RideRecording, ftp: Int) {
        self.recording = recording
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

    public mutating func start(at now: Date) {
        guard state == .ready || state == .paused else { return }
        state = .riding
        lastTick = now
    }

    public mutating func pause() {
        guard state == .riding else { return }
        state = .paused
        lastTick = nil
    }

    /// Called about once per second with the latest readings. Returns the sample recorded, if riding.
    @discardableResult
    public mutating func tick(now: Date, watts: Int?, heartRate: Int?, cadence: Int?) -> RideSample? {
        guard state == .riding else { return nil }
        if let last = lastTick { elapsed += now.timeIntervalSince(last) }
        lastTick = now
        let sample = RideSample(time: now, watts: watts, heartRate: heartRate, cadence: cadence, targetWatts: targetWatts)
        recording.samples.append(sample)
        if elapsed >= workout.totalDuration { finish(at: now) }
        return sample
    }

    public mutating func finish(at now: Date) {
        guard state != .finished else { return }
        state = .finished
        recording.endedAt = now
        lastTick = nil
    }

    public mutating func adjustIntensity(by delta: Double) {
        intensityScale = min(max(intensityScale + delta, 0.8), 1.2)
    }
}
