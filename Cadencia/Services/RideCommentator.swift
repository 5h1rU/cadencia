import AVFoundation
import Foundation
import Observation
import CadenciaCore

/// The coach's voice during a ride. Watches the engine once a second, asks the AI for one line at each
/// moment `RideCommentary.Scheduler` allows, shows it as a caption and reads it aloud over whatever
/// else is playing. One request in flight at a time; a line that arrives after its block ended is dropped.
@MainActor
@Observable
final class RideCommentator {
    struct Caption: Equatable {
        var line: RideCommentary.Line
        var moment: RideCommentary.Moment
        var at: Date
    }

    private(set) var caption: Caption?
    private(set) var thinking = false
    var voiceEnabled: Bool { didSet { if !voiceEnabled { synthesizer.stopSpeaking(at: .immediate) } } }
    var captionsEnabled: Bool

    private let coach: LLMCoach
    private let locale: String
    private var scheduler = RideCommentary.Scheduler()
    private var inFlight: Task<Void, Never>?
    /// The block the ride is in as of the last tick, so a late block-start line for a block that already ended is dropped.
    private var lastSeenStep: Int?
    private let synthesizer = AVSpeechSynthesizer()
    /// Hands the audio session back (un-ducks the music) once a line has been spoken.
    private let speechEnd = SpeechEnd()

    init(coach: LLMCoach, locale: String, voiceEnabled: Bool, captionsEnabled: Bool) {
        self.coach = coach
        self.locale = locale
        self.voiceEnabled = voiceEnabled
        self.captionsEnabled = captionsEnabled
        synthesizer.delegate = speechEnd
    }

    /// Called by `RideSession` after every tick and once on finish.
    func observe(_ engine: RideEngine, live: BluetoothManager.Live) {
        lastSeenStep = engine.currentStepIndex
        guard voiceEnabled || captionsEnabled else { return }
        let finished = engine.state == .finished
        guard let moment = scheduler.due(stepIndex: engine.currentStepIndex, elapsedInStep: engine.elapsedInStep,
                                         stepDuration: engine.currentStep?.duration ?? 0, finished: finished) else { return }
        let brief = RideCommentary.Brief(locale: locale, moment: moment, workout: engine.workout, ftp: engine.ftp,
                                         stepIndex: engine.currentStepIndex, elapsed: engine.elapsed, intensityScale: engine.intensityScale,
                                         samples: engine.recording.samples, liveHeartRate: live.heartRate, liveCadence: live.cadence)
        let stepAtRequest = engine.currentStepIndex
        inFlight?.cancel()
        thinking = true
        inFlight = Task { [weak self] in
            defer { self?.thinking = false }
            guard let self else { return }
            let line: RideCommentary.Line
            do { line = try await coach.comment(brief) } catch { return }   // silence beats a wrong line mid-effort
            guard !Task.isCancelled else { return }
            if case .blockStart = moment, stepAtRequest != lastSeenStep { return }
            deliver(line, moment: moment)
        }
    }

    func stop() {
        inFlight?.cancel()
        inFlight = nil
        synthesizer.stopSpeaking(at: .immediate)
        deactivateAudio()
    }

    private func deliver(_ line: RideCommentary.Line, moment: RideCommentary.Moment) {
        if captionsEnabled { caption = Caption(line: line, moment: moment, at: Date()) }
        guard voiceEnabled else { return }
        speak(line.caption)
    }

    private func speak(_ text: String) {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .word) }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
            try session.setActive(true)
        } catch { return }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: Self.voiceLanguage(for: locale))
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.postUtteranceDelay = 0.2
        synthesizer.speak(utterance)
    }

    private func deactivateAudio() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// The system voice closest to the athlete's language; falls back to the current locale's identifier.
    static func voiceLanguage(for code: String) -> String {
        switch code {
        case "es": return Locale.current.region?.identifier == "MX" ? "es-MX" : "es-ES"
        case "en": return Locale.current.region?.identifier == "GB" ? "en-GB" : "en-US"
        default: return Locale.current.identifier
        }
    }
}

/// Not main-actor bound: the synthesizer calls back on its own queue.
private final class SpeechEnd: NSObject, AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
