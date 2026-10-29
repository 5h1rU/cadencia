import Foundation
import Speech
import AVFoundation
import Observation

/// On-device speech-to-text for coach voice notes. Transcript updates live while listening.
@Observable
@MainActor
final class SpeechRecognizer {
    enum Status: Equatable { case idle, listening, denied, unavailable, failed(String) }

    private(set) var status: Status = .idle
    private(set) var transcript = ""

    private let audioEngine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    init(locale: Locale = .current) {
        recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer()
    }

    var isListening: Bool { status == .listening }

    func start() async {
        transcript = ""
        let speechOK = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
        guard speechOK else { status = .denied; return }
        let micOK = await AVAudioApplication.requestRecordPermission()
        guard micOK else { status = .denied; return }
        guard let recognizer, recognizer.isAvailable else { status = .unavailable; return }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
            self.request = request

            let input = audioEngine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
            audioEngine.prepare()
            try audioEngine.start()
            status = .listening

            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let result { self.transcript = result.bestTranscription.formattedString }
                    if error != nil || result?.isFinal == true { self.finishAudio() }
                }
            }
        } catch {
            status = .failed(error.localizedDescription)
            finishAudio()
        }
    }

    /// Stops capturing audio. The recognition task keeps running briefly to deliver its final, more accurate pass.
    func stop() {
        request?.endAudio()
        stopEngine()
        if status == .listening { status = .idle }
    }

    private func stopEngine() {
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func finishAudio() {
        stopEngine()
        task = nil
        request = nil
        if status == .listening { status = .idle }
    }
}
