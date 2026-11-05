import Foundation
import Speech
import AVFoundation
import Observation

/// Live speech-to-text for Coach and the consultation. Prefer Apple's on-device transcriber.
@Observable
@MainActor
final class SpeechRecognizer {
    enum Status: Equatable { case idle, preparing, listening, finishing, denied, unavailable, failed(String) }

    private(set) var status: Status = .idle
    private(set) var transcript = ""

    // Both are created on first use, not per init: SwiftUI rebuilds a `@State` default value whenever
    // the owning view is re-initialized. The microphone's blocking work runs off the main thread.
    @ObservationIgnored private lazy var microphone = MicrophoneEngine()
    @ObservationIgnored private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var finishTimeout: Task<Void, Never>?
    private var recordingID: UUID?
    /// The legacy path activated the microphone for the current recording; stopping it is this object's job.
    @ObservationIgnored private var microphoneInUse = false
    private let locale: Locale
    #if compiler(>=6.2)
    private var modernCapture: (any ConsultationSpeechCapture)?
    #endif

    init(locale: Locale = Locale(identifier: Locale.preferredLanguages.first ?? Locale.current.identifier)) {
        self.locale = locale
    }

    var isListening: Bool { status == .listening }
    var isCapturing: Bool { status == .preparing || status == .listening || status == .finishing }

    func start() async {
        guard status != .preparing, status != .finishing, !isListening else { return }
        cancel()
        transcript = ""
        status = .preparing
        let id = UUID()
        recordingID = id
        let micOK = await AVAudioApplication.requestRecordPermission()
        guard isCurrent(id) else { return }
        guard micOK else { status = .denied; return }

        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            let capture = AnalyzerSpeechCapture(microphone: microphone)
            modernCapture = capture
            do {
                try await capture.start(locale: locale, onText: { [weak self] text in
                    guard self?.recordingID == id else { return }
                    self?.transcript = text
                }, onEnd: { [weak self] error in
                    guard let self, self.recordingID == id else { return }
                    self.modernCapture = nil
                    self.recordingID = nil
                    self.status = error.map { .failed($0.localizedDescription) } ?? .idle
                })
                guard recordingID == id else { capture.cancel(); return }
                status = .listening
                return
            } catch {
                capture.cancel()
                guard isCurrent(id) else { return }
                modernCapture = nil
                // Older hardware, an unsupported locale or unavailable assets can still use the
                // legacy recognizer. The typed answer stays available if neither can start.
            }
        }
        #endif

        if recognizer == nil { recognizer = SFSpeechRecognizer(locale: locale) }
        let speechOK = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
        guard isCurrent(id) else { return }
        guard speechOK else { status = .denied; return }
        guard let recognizer, recognizer.isAvailable else { status = .unavailable; return }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Asks the speech service, which can take a moment, so it is answered off the main thread.
        let onDevice = await Task.detached(priority: .userInitiated) { recognizer.supportsOnDeviceRecognition }.value
        guard isCurrent(id) else { return }
        if onDevice { request.requiresOnDeviceRecognition = true }
        self.request = request

        do {
            microphoneInUse = true
            let format = try await microphone.activate()
            guard isCurrent(id) else { return }
            try await microphone.start(format: format, bufferSize: 1024) { buffer in request.append(buffer) }
            guard isCurrent(id) else { return }
            status = .listening

            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    guard let self, self.recordingID == id else { return }
                    if let result { self.transcript = result.bestTranscription.formattedString }
                    if result?.isFinal == true { self.finishAudio() }
                    // Finishing with nothing said ends quietly; only a failure while listening means voice is unavailable.
                    else if let error { self.finishAudio(error: self.transcript.isEmpty && self.status != .finishing ? error : nil) }
                }
            }
        } catch {
            guard recordingID == id else { return }
            finishAudio(error: error)
        }
    }

    /// Whether recording `id` may go on after an await. A cancelled task ends its own recording, so the
    /// screen never stays on "Preparing"; a newer recording or a cancel has already cleaned up.
    private func isCurrent(_ id: UUID) -> Bool {
        guard recordingID == id else { return false }
        if Task.isCancelled { cancel(); return false }
        return true
    }

    /// Stops capturing audio. The recognition task keeps running briefly to deliver its final, more accurate pass.
    func stop() {
        if status == .preparing { cancel(); return }
        guard isListening else { return }
        status = .finishing
        let id = recordingID
        finishTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            guard let self, self.recordingID == id, self.status == .finishing else { return }
            // Retain the latest transcript if recognition cannot deliver a final segment.
            self.cancel()
        }
        #if compiler(>=6.2)
        if let modernCapture { modernCapture.finish(); return }
        #endif
        request?.endAudio()
        stopEngine()
    }

    func cancel() {
        recordingID = nil
        #if compiler(>=6.2)
        modernCapture?.cancel()
        modernCapture = nil
        #endif
        task?.cancel()
        finishAudio()
    }

    private func stopEngine() {
        // Queued behind the microphone's start, so it always undoes it; cancel() never creates the engine just to check.
        guard microphoneInUse else { return }
        microphoneInUse = false
        microphone.stop()
    }

    private func finishAudio(error: Error? = nil) {
        finishTimeout?.cancel()
        finishTimeout = nil
        stopEngine()
        task = nil
        request = nil
        recordingID = nil
        status = error.map { .failed($0.localizedDescription) } ?? .idle
    }
}
