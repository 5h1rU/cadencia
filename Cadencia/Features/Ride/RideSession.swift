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
    /// The AI voice for this ride; nil when no coach is connected.
    let commentator: RideCommentator?

    let bluetooth: BluetoothManager
    private var ticker: Task<Void, Never>?
    private var lastDropSeen: Date?

    init(workout: Workout, ftp: Int, athleteID: String, plannedSessionID: UUID?, intervalsEventID: Int?, bluetooth: BluetoothManager,
         ergEnabled: Bool, commentator: RideCommentator? = nil) {
        let recording = RideRecording(athleteID: athleteID, workout: workout, plannedSessionID: plannedSessionID, intervalsEventID: intervalsEventID, startedAt: Date())
        self.engine = RideEngine(recording: recording, ftp: ftp)
        self.bluetooth = bluetooth
        self.ergEnabled = ergEnabled
        self.commentator = commentator
    }

    var live: BluetoothManager.Live { bluetooth.live }
    var state: RideEngine.State { engine.state }
    var recording: RideRecording { engine.recording }

    func start() {
        guard engine.state == .ready else { return }
        var recording = engine.recording
        recording.startedAt = Date()
        engine = RideEngine(recording: recording, ftp: engine.ftp)
        engine.start(at: recording.startedAt)
        UIApplication.shared.isIdleTimerDisabled = true
        if ergEnabled { bluetooth.resumeTrainer() }
        sendTarget()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.tick()
            }
        }
    }

    func pause() {
        guard engine.state == .riding else { return }
        engine.pause()
        if ergEnabled { bluetooth.pauseTrainer() }
    }

    func resume() {
        guard engine.state == .paused else { return }
        engine.start(at: Date())
        if ergEnabled { bluetooth.resumeTrainer() }
        sendTarget()
    }

    func finish() -> RideRecording {
        ticker?.cancel()
        ticker = nil
        engine.finish(at: Date())
        bluetooth.releaseControl()
        UIApplication.shared.isIdleTimerDisabled = false
        // Ending early is the athlete's call; the voice stops rather than commenting on it.
        commentator?.stop()
        return engine.recording
    }

    func adjustIntensity(by delta: Double) {
        engine.adjustIntensity(by: delta)
        sendTarget()
    }

    func acknowledgeTrainerLoss() { trainerLostAlert = false }

    private func tick() {
        guard engine.state == .riding else { return }
        let now = Date()
        // Stale sensor values (no packet in 5 s) count as missing rather than frozen.
        let fresh = live.updatedAt.map { now.timeIntervalSince($0) < 5 } ?? false
        _ = engine.tick(now: now, watts: fresh ? live.watts : nil, heartRate: fresh ? live.heartRate : nil, cadence: fresh ? live.cadence : nil)
        if engine.state == .finished {
            // The last block ran out: the engine closed the recording itself.
            ticker?.cancel()
            ticker = nil
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

    private func sendTarget() {
        guard ergEnabled, engine.state == .riding, let target = engine.targetWatts else { return }
        bluetooth.setTargetPower(target)
    }
}
