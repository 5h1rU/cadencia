import Foundation

/// Emits at most one cue per remaining second in each block. A delayed tick skips missed cues;
/// pausing preserves the last cue so resuming cannot replay the same second.
public struct BlockCountdown: Equatable, Sendable {
    private var lastCue: Cue?

    private struct Cue: Equatable, Sendable {
        let step: Int
        let seconds: Int
    }

    public init() {}

    public mutating func update(for engine: RideEngine) -> Int? {
        guard engine.state == .riding, let step = engine.currentStepIndex else { return nil }
        let seconds = Int(engine.remainingInStep.rounded(.up))
        guard (1...3).contains(seconds) else { return nil }
        let cue = Cue(step: step, seconds: seconds)
        guard cue != lastCue else { return nil }
        lastCue = cue
        return seconds
    }
}
