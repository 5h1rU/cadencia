import Foundation
import Observation
import UIKit
import CadenciaCore

/// Drives one trainer ride: ticks the pure `RideEngine` once a second with live sensor values,
/// pushes ERG targets to the trainer and keeps the screen awake. Owns nothing persistent; the
/// finished `RideRecording` is handed to `AppModel`.
@MainActor
@Observable
final class RideSession {
    private(set) var engine: RideEngine
    var ergEnabled: Bool
    private(set) var trainerLostAlert = false
    /// Share of the current block's seconds so far spent inside the zone. Kept in step with the engine's clock
    /// so the HUD doesn't recompute it from the recording on every sensor packet.
    private(set) var blockInZonePercent: Int?
    /// The AI voice for this ride; nil when no coach is connected.
    let commentator: RideCommentator?
    var countdownBeepsEnabled = true {
        didSet { if !countdownBeepsEnabled { audio.stopCountdown() } }
    }

    let bluetooth: BluetoothManager
    private var ticker: Task<Void, Never>?
    private var lastDropSeen: Date?
    private var countdown = BlockCountdown()
    private let audio: RideAudio

    init(workout: Workout, ftp: Int, athleteID: String, plannedSessionID: UUID?, intervalsEventID: Int?, bluetooth: BluetoothManager,
         ergEnabled: Bool, commentator: RideCommentator? = nil) {
        let recording = RideRecording(athleteID: athleteID, workout: workout, plannedSessionID: plannedSessionID, intervalsEventID: intervalsEventID, startedAt: Date())
        self.engine = RideEngine(recording: recording, ftp: ftp)
        self.bluetooth = bluetooth
        self.ergEnabled = ergEnabled
        self.commentator = commentator
        self.audio = commentator?.audio ?? RideAudio()
    }

    /// The latest sensor readings, with power, cadence and heart rate that went stale (no packet in 5 s) removed.
    var live: BluetoothManager.Live {
        #if DEBUG
        if let previewLive { return previewLive }
        #endif
        return bluetooth.live.fresh(at: Date())
    }
    var state: RideEngine.State { engine.state }
    var recording: RideRecording { engine.recording }

    func start() {
        guard engine.state == .ready else { return }
        // BluetoothManager outlives rides and keeps its last trainer drop; only a drop during this ride pauses it.
        lastDropSeen = bluetooth.trainerDroppedAt
        var recording = engine.recording
        recording.startedAt = Date()
        engine = RideEngine(recording: recording, ftp: engine.ftp)
        engine.start(at: recording.startedAt, trainerDistanceMeters: freshTrainerDistance(at: recording.startedAt))
        UIApplication.shared.isIdleTimerDisabled = true
        if ergEnabled { bluetooth.resumeTrainer() }
        sendTarget()
        playCountdownIfDue()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                // Bound only after the sleep, so a session released without finish() ends the loop.
                guard let self, !Task.isCancelled else { return }
                self.tick()
            }
        }
    }

    func pause() {
        guard engine.state == .riding else { return }
        engine.pause(at: Date())
        refreshBlockInZone()
        audio.stopCountdown()
        if ergEnabled { bluetooth.pauseTrainer() }
    }

    func resume() {
        guard engine.state == .paused else { return }
        let now = Date()
        engine.start(at: now, trainerDistanceMeters: freshTrainerDistance(at: now))
        if ergEnabled { bluetooth.resumeTrainer() }
        sendTarget()
        playCountdownIfDue()
    }

    func finish() -> RideRecording {
        let ranToEnd = engine.state == .finished
        ticker?.cancel()
        ticker = nil
        engine.finish(at: Date())
        refreshBlockInZone()
        bluetooth.releaseControl()
        UIApplication.shared.isIdleTimerDisabled = false
        // Ending early is the athlete's call, so the voice stops rather than commenting on it. A workout that
        // ran to its end keeps the closing line the last tick requested; only the voice can deliver it,
        // because Review replaces this screen and its caption.
        if !ranToEnd || commentator?.voiceEnabled != true { commentator?.stop() }
        audio.stopCountdown()
        return engine.recording
    }

    func adjustIntensity(by delta: Double) {
        engine.adjustIntensity(by: delta)
        sendTarget()
    }

    func acknowledgeTrainerLoss() { trainerLostAlert = false }

    func keepRiding() { engine.dismissPauseSuggestion() }

    private func tick() {
        guard engine.state == .riding else { return }
        let now = Date()
        // Stale sensor values (no packet in 5 s) count as missing rather than frozen; `live` already leaves out
        // stale power, cadence and heart rate.
        let freshPower = live.wattsUpdatedAt.map { now.timeIntervalSince($0) < 5 } ?? false
        let freshCadence = live.cadenceUpdatedAt.map { now.timeIntervalSince($0) < 5 } ?? false
        let speedFresh = live.speedUpdatedAt.map { now.timeIntervalSince($0) < 5 } ?? false
        _ = engine.tick(now: now, watts: freshPower ? live.watts : nil, heartRate: live.heartRate, cadence: freshCadence ? live.cadence : nil,
                        speedKmh: speedFresh ? live.speedKmh : nil, trainerDistanceMeters: freshTrainerDistance(at: now))
        refreshBlockInZone()
        playCountdownIfDue()
        if engine.state == .finished {
            // The last block ran out: the engine closed the recording itself.
            ticker?.cancel()
            ticker = nil
            audio.stopCountdown()
            bluetooth.releaseControl()
            UIApplication.shared.isIdleTimerDisabled = false
            commentator?.observe(engine, live: live)
            return
        }
        commentator?.observe(engine, live: live)
        sendTarget()
        if let dropped = bluetooth.trainerDroppedAt, dropped != lastDropSeen {
            lastDropSeen = dropped
            trainerLostAlert = true
            pause()
        }
    }

    /// Recomputes `blockInZonePercent` from this block's samples only. The slice keeps the last sample before
    /// the block, whose reading can cover the block's first second, and the timeline keeps the recording's first
    /// sample as its origin, so the result is the same as a pass over the whole recording.
    private func refreshBlockInZone() {
        guard let i = engine.currentStepIndex, engine.elapsedInStep >= 10 else { blockInZonePercent = nil; return }
        let samples = engine.recording.samples
        let blockStart = engine.workout.steps[..<i].reduce(0) { $0 + $1.duration }
        let from = samples.lastIndex { ($0.workoutElapsed ?? 0) < blockStart } ?? samples.startIndex
        blockInZonePercent = RideCommentary.BlockStats.compute(index: i, workout: engine.workout, ftp: engine.ftp, samples: Array(samples[from...]),
                                                               upTo: engine.elapsed, startedAt: samples.first?.time).inZonePercent
    }

    private func freshTrainerDistance(at now: Date) -> Int? {
        guard let updatedAt = live.distanceUpdatedAt, now.timeIntervalSince(updatedAt) < 5 else { return nil }
        return live.totalDistanceMeters
    }

    private func sendTarget() {
        guard ergEnabled, engine.state == .riding, let target = engine.targetWatts else { return }
        bluetooth.setTargetPower(target)
    }

    private func playCountdownIfDue() {
        let cue = countdown.update(for: engine)
        if cue != nil, countdownBeepsEnabled { audio.playCountdown() }
    }

    #if DEBUG
    private var previewLive: BluetoothManager.Live?

    /// Frozen, local-only HUD fixture: no trainer control, network calls, or saved ride.
    static func hudPreview(longRide: Bool) -> RideSession {
        let workout = Workout(name: "Fresh legs", kind: .endurance, steps: [
            .init(name: "Gentle warm-up", duration: 480, startIntensity: 0.4, endIntensity: 0.6),
            .init(name: "Comfortable aerobic riding", duration: longRide ? 10_020 : 1320, intensity: 0.65),
            .init(name: "Cool-down", duration: 300, intensity: 0.4),
        ])
        let session = RideSession(workout: workout, ftp: 200, athleteID: "preview", plannedSessionID: nil,
                                  intervalsEventID: nil, bluetooth: BluetoothManager(), ergEnabled: false,
                                  commentator: .hudPreview())
        let elapsed: TimeInterval = longRide ? 3789 : 189
        let start = Date().addingTimeInterval(-elapsed)
        session.engine.start(at: start)
        for second in 0...Int(elapsed) {
            let watts = workout.targetWatts(ftp: 200, at: Double(second)) ?? 95
            session.engine.tick(now: start.addingTimeInterval(Double(second)), watts: watts, heartRate: 93, cadence: 78)
        }
        session.previewLive = .init(watts: session.engine.targetWatts, heartRate: 93, cadence: 78)
        session.refreshBlockInZone()
        return session
    }
    #endif
}
