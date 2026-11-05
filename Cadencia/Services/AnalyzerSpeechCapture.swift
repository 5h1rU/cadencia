#if compiler(>=6.2)
// AVFAudio is not Sendable-annotated yet; the converter tap hands its borrowed buffer to a synchronous input block.
@preconcurrency import AVFoundation
import Speech

@MainActor
protocol ConsultationSpeechCapture: AnyObject {
    func finish()
    func cancel()
}

/// A single microphone turn. Apple installs the locale assets when needed, then the analyzer
/// delivers volatile and final text segments without sending the microphone stream to the coach.
@available(iOS 26.0, *)
@MainActor
final class AnalyzerSpeechCapture: ConsultationSpeechCapture {
    private enum CaptureError: Error { case unsupported, invalidFormat, conversionFailed }
    private let microphone: MicrophoneEngine
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncThrowingStream<AnalyzerInput, Error>.Continuation?
    private var analysisTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Error>?
    /// This capture activated the shared microphone and has not stopped it yet.
    private var microphoneInUse = false
    private var cancelled = false

    init(microphone: MicrophoneEngine) {
        self.microphone = microphone
    }

    func start(locale: Locale, onText: @escaping (String) -> Void, onEnd: @escaping (Error?) -> Void) async throws {
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { throw CaptureError.unsupported }
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        if let assets = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await assets.downloadAndInstall()
        }
        try checkCurrent()
        // The session and the input node block on the audio server, so the microphone answers off the main thread.
        microphoneInUse = true
        let microphoneFormat = try await microphone.activate()
        try checkCurrent()
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: microphoneFormat),
              let converter = AVAudioConverter(from: microphoneFormat, to: format) else { throw CaptureError.invalidFormat }
        try checkCurrent()
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        try await analyzer.prepareToAnalyze(in: format)
        try checkCurrent()
        let (stream, continuation) = AsyncThrowingStream<AnalyzerInput, Error>.makeStream()
        input = continuation

        let results = Task {
            var final = ""
            for try await result in transcriber.results {
                let segment = String(result.text.characters)
                let separator = final.isEmpty || final.last?.isWhitespace == true || segment.first?.isWhitespace == true ? "" : " "
                let text = final + separator + segment
                if result.isFinal { final = text }
                onText(text)
            }
        }
        resultsTask = results
        analysisTask = Task { [weak self] in
            do {
                if let end = try await analyzer.analyzeSequence(stream) {
                    try await analyzer.finalizeAndFinish(through: end)
                } else { await analyzer.cancelAndFinishNow() }
                try await results.value
                guard let self, !self.cancelled else { return }
                self.stopMicrophone()
                onEnd(nil)
            } catch {
                await analyzer.cancelAndFinishNow()
                results.cancel()
                guard let self, !self.cancelled else { return }
                self.stopMicrophone()
                onEnd(error)
            }
        }

        try await microphone.start(format: microphoneFormat, bufferSize: 2048,
                                   tap: Self.converting(from: microphoneFormat, to: format, with: converter, into: continuation))
        try checkCurrent()
    }

    /// The microphone tap: converts each buffer into the analyzer's format and yields it. It runs on the audio
    /// thread, so it is built outside the main actor and touches only what it captures.
    private nonisolated static func converting(from microphoneFormat: AVAudioFormat, to format: AVAudioFormat, with converter: AVAudioConverter,
                                               into continuation: AsyncThrowingStream<AnalyzerInput, Error>.Continuation) -> @Sendable (AVAudioPCMBuffer) -> Void {
        let ratio = format.sampleRate / microphoneFormat.sampleRate
        return { buffer in
            // The tap's buffer is borrowed. Convert into an owned buffer before yielding it.
            let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio)) + 64
            guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
                continuation.finish(throwing: CaptureError.conversionFailed)
                return
            }
            var error: NSError?
            var supplied = false
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                inputStatus.pointee = supplied ? .noDataNow : .haveData
                defer { supplied = true }
                return supplied ? nil : buffer
            }
            guard status != .error else {
                continuation.finish(throwing: error ?? CaptureError.conversionFailed as NSError)
                return
            }
            if output.frameLength > 0 { continuation.yield(AnalyzerInput(buffer: output)) }
        }
    }

    func finish() {
        stopMicrophone()
        input?.finish()
        input = nil
    }

    func cancel() {
        cancelled = true
        finish()
        resultsTask?.cancel()
        analysisTask?.cancel()
        if let analyzer { Task { await analyzer.cancelAndFinishNow() } }
    }

    private func checkCurrent() throws {
        if cancelled { throw CancellationError() }
        try Task.checkCancellation()
    }

    private func stopMicrophone() {
        // Queued behind the microphone's start, so it always undoes it, off the main thread.
        guard microphoneInUse else { return }
        microphoneInUse = false
        microphone.stop()
    }
}
#endif
