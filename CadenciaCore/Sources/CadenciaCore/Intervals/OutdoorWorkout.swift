import Foundation

public enum RideLocation: String, Codable, CaseIterable, Sendable {
    case indoor, outdoor
}

public enum OutdoorDevice: String, Codable, CaseIterable, Sendable {
    case garmin, magene
}

/// A delivery snapshot. Absolute targets cannot be increased by a different FTP on the head unit.
public struct OutdoorWorkout: Equatable, Sendable {
    public let workout: Workout
    public let ftp: Int

    public init(workout: Workout, prescriptionFTP: Int, outdoorFTP: Int) {
        ftp = max(outdoorFTP, 1)
        // A location change may soften today's prescription, but may never raise its watts.
        let scale = min(1, Double(max(prescriptionFTP, 1)) / Double(ftp))
        var prepared = workout
        prepared.steps = workout.steps.map { step in
            var step = step
            step.startIntensity = min(step.startIntensity, workout.intensityCeiling ?? step.startIntensity) * scale
            step.endIntensity = min(step.endIntensity, workout.intensityCeiling ?? step.endIntensity) * scale
            return step
        }
        prepared.intensityCeiling = workout.intensityCeiling.map { $0 * scale }
        self.workout = prepared
    }

    public var text: String { WorkoutText.render(workout, ftp: ftp) }

    public func revision(on day: Day) -> String {
        let input = "\(day.iso)|\(workout.id)|\(ftp)|\(workout.name)|\(text)"
        return SHA256.hash(Array(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Only an explicit Intervals pairing can automatically complete a planned outdoor session.
/// Same-day/time/name guesses would incorrectly complete sessions after an unrelated ride.
public enum OutdoorRideImport {
    /// Free rides are reviewable too, but only explicit provider pairing completes a prescription.
    public static func recording(activity: ActivitySummary, sessions: [PlannedSession], athleteID: String,
                                 fallbackFTP: Int, existing: RideRecording? = nil) -> RideRecording? {
        guard activity.isCycling, !activity.isTrainer, activity.type != "VirtualRide" else { return nil }
        let session = sessions.first { matches(activity, session: $0) }
        let workout = session?.deliveredWorkout ?? session?.workout ?? Workout(name: activity.name, kind: .endurance, steps: [])
        var ride = existing ?? RideRecording(id: recordingID(athleteID: athleteID, activityID: activity.id),
            athleteID: athleteID, workout: workout, startedAt: activity.startDateLocal)
        ride.sourceActivity = activity
        ride.endedAt = activity.startDateLocal.addingTimeInterval(activity.movingTime)
        ride.ftpUsed = session?.deliveredFTP ?? activity.ftpAtTime ?? ride.ftpUsed ?? fallbackFTP
        if let session {
            ride.plannedSessionID = session.id; ride.intervalsEventID = session.intervalsEventID
            ride.workout = workout
            if ride.plannedRoute == nil { ride.plannedRoute = session.route }
        }
        return ride
    }

    public static func matches(_ activity: ActivitySummary, session: PlannedSession) -> Bool {
        guard let eventID = session.intervalsEventID, session.location == .outdoor else { return false }
        return activity.isCycling && !activity.isTrainer && activity.pairedEventID == eventID
    }

    public static func recordingID(athleteID: String, activityID: String) -> UUID {
        let b = SHA256.hash(Array("outdoor|\(athleteID)|\(activityID)".utf8))
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
}
