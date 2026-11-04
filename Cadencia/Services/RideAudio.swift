import AVFoundation
import Foundation

/// Shares the audio session between coach speech and short, local block-ending tones.
/// Ending a tone must not deactivate speech that is still playing (and vice versa).
@MainActor
final class RideAudio: NSObject, AVAudioPlayerDelegate {
    private var voiceActive = false
    private var countdownActive = false
    private var tone: AVAudioPlayer?

    func activateVoice() -> Bool {
        voiceActive = true
        if activate() { return true }
        voiceActive = false
        return false
    }

    func deactivateVoice() {
        voiceActive = false
        releaseIfIdle()
    }

    func playCountdown() {
        if tone == nil {
            tone = try? AVAudioPlayer(data: Self.toneData())
            tone?.delegate = self
            tone?.prepareToPlay()
        }
        guard let tone else { return }
        countdownActive = true
        guard activate() else { countdownActive = false; return }
        tone.currentTime = 0
        if !tone.play() { stopCountdown() }
    }

    func stopCountdown() {
        tone?.stop()
        countdownActive = false
        releaseIfIdle()
    }

    private func activate() -> Bool {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: voiceActive ? .spokenAudio : .default,
                                    options: voiceActive ? [.duckOthers, .interruptSpokenAudioAndMixWithOthers] : [.mixWithOthers])
            try session.setActive(true)
            return true
        } catch { return false }
    }

    private func releaseIfIdle() {
        if voiceActive || countdownActive {
            _ = activate()
        } else {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.tone?.isPlaying != true else { return }
            self.countdownActive = false
            self.releaseIfIdle()
        }
    }

    /// A 120 ms, 880 Hz PCM tone, with a short fade at both ends to avoid clicks. No network or asset.
    private static func toneData() -> Data {
        let sampleRate = 44_100
        let count = Int(Double(sampleRate) * 0.12)
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8)
        append(UInt32(36 + count * 2))
        data.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16))
        append(UInt16(1)) // PCM
        append(UInt16(1)) // Mono
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2))
        append(UInt16(2))
        append(UInt16(16))
        data.append(contentsOf: "data".utf8)
        append(UInt32(count * 2))
        let fade = Double(sampleRate) * 0.005
        for i in 0..<count {
            let envelope = min(1, Double(i) / fade, Double(count - 1 - i) / fade)
            let wave = sin(2 * .pi * 880 * Double(i) / Double(sampleRate))
            append(Int16(wave * envelope * 16_000))
        }
        return data
    }
}
