#if compiler(>=6.2)
import AVFoundation
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
    private let engine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncThrowingStream<AnalyzerInput, Error>.Continuation?
    private var analysisTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Error>?
    private var tapInstalled = false
    private var sessionActive = false
    private var cancelled = false

    func start(locale: Locale, onText: @escaping (String) -> Void, onEnd: @escaping (Error?) -> Void) async throws {
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { throw CaptureError.unsupported }
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        if let assets = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await assets.downloadAndInstall()
        }
        try checkCurrent()
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement)
        try session.setActive(true)
        sessionActive = true
        let node = engine.inputNode
        let microphoneFormat = node.outputFormat(forBus: 0)
        guard microphoneFormat.sampleRate > 0, microphoneFormat.channelCount > 0,
              let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: microphoneFormat),
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

        let ratio = format.sampleRate / microphoneFormat.sampleRate
        node.installTap(onBus: 0, bufferSize: 2048, format: microphoneFormat) { buffer, _ in
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
        tapInstalled = true
        engine.prepare()
        try engine.start()
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
        if engine.isRunning { engine.stop() }
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        if sessionActive {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            sessionActive = false
        }
    }
}
#endif
