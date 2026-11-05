import AVFoundation

/// The microphone side of voice input: the record session and an input tap on an `AVAudioEngine`.
///
/// Activating the session and touching the engine's input node block until the audio server answers
/// (over two seconds on first use in the Simulator, hundreds of milliseconds on a phone), so every call's
/// work runs on one serial queue shared by all instances, never on the main thread. The queue's order is also
/// the safety net: callers are on the main actor and each call queues its work before it returns or suspends,
/// so a stop issued after a start always runs after it, and a later start always finds the session the
/// earlier stop left behind.
final class MicrophoneEngine: @unchecked Sendable {
    enum Failure: Error { case noInput, formatChanged }

    private static let queue = DispatchQueue(label: "com.felipejaner.cadencia.microphone", qos: .userInitiated)

    // Touched only on `queue`.
    private var engine: AVAudioEngine?
    private var tapInstalled = false
    private var sessionActive = false

    /// Activates a record session and returns the microphone's format. Call `stop()` afterwards, even when it throws.
    @MainActor func activate() async throws -> AVAudioFormat {
        try await run { [self] in
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement)
            try session.setActive(true)
            sessionActive = true
            let engine = engine ?? AVAudioEngine()
            self.engine = engine
            let format = engine.inputNode.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { throw Failure.noInput }
            return format
        }
    }

    /// Installs `tap` on the microphone in `format` (what `activate()` returned) and starts the engine. `tap` runs on
    /// the audio thread. Throws instead of crashing when the input changed in between, as when headphones connect.
    @MainActor func start(format: AVAudioFormat, bufferSize: AVAudioFrameCount, tap: @escaping @Sendable (AVAudioPCMBuffer) -> Void) async throws {
        try await run { [self] in
            guard let engine else { throw Failure.noInput }
            let input = engine.inputNode
            guard input.outputFormat(forBus: 0) == format else { throw Failure.formatChanged }
            if tapInstalled { input.removeTap(onBus: 0) }
            input.installTap(onBus: 0, bufferSize: bufferSize, format: format) { buffer, _ in tap(buffer) }
            tapInstalled = true
            engine.prepare()
            try engine.start()
        }
    }

    /// Stops the engine, removes the tap and deactivates the session. Returns at once; repeated calls are harmless.
    func stop() {
        Self.queue.async { [self] in
            if let engine {
                if engine.isRunning { engine.stop() }
                if tapInstalled { engine.inputNode.removeTap(onBus: 0) }
            }
            tapInstalled = false
            if sessionActive {
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                sessionActive = false
            }
        }
    }

    /// Queues `work` before the caller suspends, which is why this and its callers are main-actor methods: a
    /// nonisolated async method first hops to the global executor, so a `stop()` issued meanwhile could be queued
    /// ahead of it. `work` is `@Sendable`, so it stays nonisolated and runs on the queue.
    @MainActor private func run<T>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            Self.queue.async { continuation.resume(with: Result(catching: work)) }
        }
    }
}
