import AVFoundation
import Foundation
import Observation
import CadenciaCore

/// The coach's voice during a ride. Watches the engine once a second, asks the AI for one line at each
/// moment `RideCommentary.Scheduler` allows, shows it as a caption and reads it aloud over whatever
/// else is playing. One request in flight at a time; a line that arrives after its block ended is dropped.
///
/// Speech comes from OpenAI text-to-speech when an API key is configured (`OpenAISpeech`); otherwise, and
/// whenever that call fails, from the best voice installed on the phone for the athlete's language.
@MainActor
@Observable
final class RideCommentator {
    struct Caption: Equatable {
        var line: RideCommentary.Line
        var moment: RideCommentary.Moment
        var at: Date
    }

    /// OpenAI text-to-speech credentials. The ChatGPT plan sign-in cannot reach `/v1/audio/speech`.
    struct OpenAISpeech: Sendable {
        var transport: any HTTPTransport
        var endpoint: URL
        var apiKey: String
        var voice: String
    }

    private(set) var caption: Caption?
    private(set) var thinking = false
    var voiceEnabled: Bool { didSet { if !voiceEnabled { silence() } } }
    var captionsEnabled: Bool

    private let coach: LLMCoach
    private let locale: String
    private let openAISpeech: OpenAISpeech?
    private var scheduler = RideCommentary.Scheduler()
    private var inFlight: Task<Void, Never>?
    private var speaking: Task<Void, Never>?
    /// The block the ride is in as of the last tick, so a late block-start line for a block that already ended is dropped.
    private var lastSeenStep: Int?
    private let synthesizer = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    /// Hands the audio session back (un-ducks the music) once a line has been played.
    private let playbackEnd = PlaybackEnd()

    init(coach: LLMCoach, locale: String, openAISpeech: OpenAISpeech?, voiceEnabled: Bool, captionsEnabled: Bool) {
        self.coach = coach
        self.locale = locale
        self.openAISpeech = openAISpeech
        self.voiceEnabled = voiceEnabled
        self.captionsEnabled = captionsEnabled
        synthesizer.delegate = playbackEnd
    }

    /// Which engine will speak: the OpenAI voice name, or nil for the phone's voice.
    var openAIVoice: String? { openAISpeech?.voice }

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
        silence()
    }

    private func deliver(_ line: RideCommentary.Line, moment: RideCommentary.Moment) {
        if captionsEnabled { caption = Caption(line: line, moment: moment, at: Date()) }
        guard voiceEnabled else { return }
        speaking?.cancel()
        speaking = Task { [weak self] in
            guard let self else { return }
            if let openAISpeech, let data = await fetchSpeech(line.caption, with: openAISpeech), !Task.isCancelled {
                play(data)
            } else if !Task.isCancelled {
                speakOnDevice(line.caption)
            }
        }
    }

    private func silence() {
        speaking?.cancel()
        speaking = nil
        synthesizer.stopSpeaking(at: .immediate)
        player?.stop()
        player = nil
        deactivateCoachAudio()
    }

    // MARK: OpenAI voice

    private func fetchSpeech(_ text: String, with speech: OpenAISpeech) async -> Data? {
        guard let request = CoachVoice.request(text: text, voice: speech.voice, locale: locale, endpoint: speech.endpoint, apiKey: speech.apiKey) else { return nil }
        guard let response = try? await speech.transport.send(request), response.isSuccess, !response.body.isEmpty else { return nil }
        return response.body
    }

    private func play(_ data: Data) {
        guard activateAudio(), let player = try? AVAudioPlayer(data: data) else { speakOnDevice(nil); return }
        player.delegate = playbackEnd
        self.player = player
        player.play()
    }

    // MARK: On-device voice

    private func speakOnDevice(_ text: String?) {
        guard let text, activateAudio() else { return }
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .word) }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.bestVoice(for: locale)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.06
        utterance.pitchMultiplier = 1.05
        utterance.postUtteranceDelay = 0.2
        synthesizer.speak(utterance)
    }

    /// The highest-quality installed voice for the language (premium > enhanced > compact), preferring the
    /// region the phone is set to.
    static func bestVoice(for code: String) -> AVSpeechSynthesisVoice? {
        let language = voiceLanguage(for: code)
        let prefix = String(language.prefix(2))
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(prefix) }
        func rank(_ v: AVSpeechSynthesisVoice) -> Int {
            var r = 0
            switch v.quality {
            case .premium: r += 20
            case .enhanced: r += 10
            default: break
            }
            if v.language == language { r += 5 }
            return r
        }
        return candidates.max { rank($0) < rank($1) } ?? AVSpeechSynthesisVoice(language: language)
    }

    /// The system voice closest to the athlete's language; falls back to the current locale's identifier.
    static func voiceLanguage(for code: String) -> String {
        switch code {
        case "es": return Locale.current.region?.identifier == "MX" ? "es-MX" : "es-ES"
        case "en": return Locale.current.region?.identifier == "GB" ? "en-GB" : "en-US"
        default: return Locale.current.identifier
        }
    }

    // MARK: Audio session

    private func activateAudio() -> Bool {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
            try session.setActive(true)
            return true
        } catch { return false }
    }

}

/// Hands the audio session back so the athlete's music comes up again.
private func deactivateCoachAudio() {
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
}

/// Not main-actor bound: the synthesizer and player call back on their own queues.
private final class PlaybackEnd: NSObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { deactivateCoachAudio() }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) { deactivateCoachAudio() }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { deactivateCoachAudio() }
}
