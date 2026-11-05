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

    private let audioEngine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var finishTimeout: Task<Void, Never>?
    private var recordingID: UUID?
    private var tapInstalled = false
    private var sessionActive = false
    private let locale: Locale
    #if compiler(>=6.2)
    private var modernCapture: (any ConsultationSpeechCapture)?
    #endif

    init(locale: Locale = Locale(identifier: Locale.preferredLanguages.first ?? Locale.current.identifier)) {
        self.locale = locale
        recognizer = SFSpeechRecognizer(locale: locale)
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
        guard recordingID == id, !Task.isCancelled else { return }
        guard micOK else { status = .denied; return }

        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            let capture = AnalyzerSpeechCapture()
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
                guard recordingID == id, !Task.isCancelled else { return }
                modernCapture = nil
                // Older hardware, an unsupported locale or unavailable assets can still use the
                // legacy recognizer. The typed answer stays available if neither can start.
            }
        }
        #endif

        let speechOK = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
        guard recordingID == id, !Task.isCancelled else { return }
        guard speechOK else { status = .denied; return }
        guard let recognizer, recognizer.isAvailable else { status = .unavailable; return }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement)
            try session.setActive(true)
            sessionActive = true

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
            self.request = request

            let input = audioEngine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { stopEngine(); status = .unavailable; return }
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
            tapInstalled = true
            audioEngine.prepare()
            try audioEngine.start()
            status = .listening

            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    guard let self, self.recordingID == id else { return }
                    if let result { self.transcript = result.bestTranscription.formattedString }
                    if result?.isFinal == true { self.finishAudio() }
                    else if let error { self.finishAudio(error: self.transcript.isEmpty ? error : nil) }
                }
            }
        } catch {
            finishAudio(error: error)
        }
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
        if audioEngine.isRunning { audioEngine.stop() }
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if sessionActive {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            sessionActive = false
        }
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
