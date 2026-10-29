import Foundation

/// One ride's journey to Intervals.icu. The ride is committed locally first; this entry tracks delivery.
public struct UploadEntry: Codable, Equatable, Sendable, Identifiable {
    public enum State: String, Codable, Sendable {
        case pending          // never attempted, or attempted with a clean failure
        case uncertain        // request sent, no acknowledged response: reconcile before retrying
        case needsReconnect   // credential rejected; keep the ride, ask the user to reconnect the same athlete
        case confirmed        // Intervals acknowledged and returned an activity id
    }

    public var id: UUID { rideID }
    public var rideID: UUID
    public var athleteID: String
    public var state: State
    public var attempts: Int
    public var lastAttemptAt: Date?
    public var lastError: String?
    public var intervalsActivityID: String?
    public var confirmedAt: Date?
    public var feedbackSynced: Bool

    public init(rideID: UUID, athleteID: String, state: State = .pending, attempts: Int = 0, lastAttemptAt: Date? = nil,
                lastError: String? = nil, intervalsActivityID: String? = nil, confirmedAt: Date? = nil, feedbackSynced: Bool = false) {
        self.rideID = rideID
        self.athleteID = athleteID
        self.state = state
        self.attempts = attempts
        self.lastAttemptAt = lastAttemptAt
        self.lastError = lastError
        self.intervalsActivityID = intervalsActivityID
        self.confirmedAt = confirmedAt
        self.feedbackSynced = feedbackSynced
    }

    /// Exponential backoff: 0, 30 s, 2 min, 8 min, 30 min, capped at 30 min.
    public func isDue(now: Date) -> Bool {
        guard state == .pending || state == .uncertain else { return false }
        guard let last = lastAttemptAt else { return true }
        let delay = min(30 * pow(4.0, Double(max(attempts - 1, 0))), 1800)
        return now.timeIntervalSince(last) >= delay
    }
}

/// Pure state machine for the upload ledger. The app wraps it with persistence and the Intervals client.
public struct UploadLedger: Codable, Equatable, Sendable {
    public private(set) var entries: [UploadEntry]

    public init(entries: [UploadEntry] = []) {
        self.entries = entries
    }

    public func entry(for rideID: UUID) -> UploadEntry? { entries.first { $0.rideID == rideID } }

    public func pending(for athleteID: String) -> [UploadEntry] {
        entries.filter { $0.athleteID == athleteID && $0.state != .confirmed }
    }

    public func due(for athleteID: String, now: Date) -> [UploadEntry] {
        pending(for: athleteID).filter { $0.isDue(now: now) }
    }

    public mutating func enqueue(rideID: UUID, athleteID: String) {
        guard entry(for: rideID) == nil else { return }
        entries.append(UploadEntry(rideID: rideID, athleteID: athleteID))
    }

    public mutating func markAttempt(_ rideID: UUID, at now: Date) {
        update(rideID) { $0.attempts += 1; $0.lastAttemptAt = now; $0.lastError = nil }
    }

    public mutating func markConfirmed(_ rideID: UUID, activityID: String, at now: Date) {
        update(rideID) { $0.state = .confirmed; $0.intervalsActivityID = activityID; $0.confirmedAt = now; $0.lastError = nil }
    }

    /// Classifies a failure. Auth failures park the entry; transport failures after the request was
    /// sent are *uncertain* (the server may have the file) and must be reconciled by `external_id` first.
    public mutating func markFailure(_ rideID: UUID, error: HTTPError, requestWasSent: Bool) {
        update(rideID) {
            $0.lastError = String(describing: error)
            if error.isAuthFailure {
                $0.state = .needsReconnect
            } else if requestWasSent, case .transport = error {
                $0.state = .uncertain
            } else {
                $0.state = .pending
            }
        }
    }

    public mutating func markFeedbackSynced(_ rideID: UUID) {
        update(rideID) { $0.feedbackSynced = true }
    }

    /// When the user reconnects, only entries for the *same* athlete resume. Others stay parked.
    public mutating func reconnect(athleteID: String) {
        for i in entries.indices where entries[i].athleteID == athleteID && entries[i].state == .needsReconnect {
            entries[i].state = .pending
        }
    }

    private mutating func update(_ rideID: UUID, _ body: (inout UploadEntry) -> Void) {
        guard let i = entries.firstIndex(where: { $0.rideID == rideID }) else { return }
        body(&entries[i])
    }
}
