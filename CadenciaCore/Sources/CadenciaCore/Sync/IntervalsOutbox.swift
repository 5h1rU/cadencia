import Foundation

/// Local changes on their way to Intervals. Intervals is the source of truth; Cadencia's copies are a cache.
/// A change is queued here in the same state transaction that shows it, sent by the next sync, and dropped
/// once Intervals holds it. While a change is queued, a refresh lays it over what Intervals returned, so
/// it is never undone by a read that ran first. Every write is an idempotent PUT of absolute values.
///
/// The accepted FTP is queued as `AppState.acceptedFTP` (it predates this type) and passed to `flush`.
public struct IntervalsOutbox: Codable, Equatable, Sendable {
    /// At most one update per day; newer edits of a day merge into it.
    public var wellness: [WellnessUpdate]
    public var heightCm: Double?
    public var measurementPreference: String?
    public var availability: [IntervalsAvailabilityDay]?

    public init(wellness: [WellnessUpdate] = [], heightCm: Double? = nil, measurementPreference: String? = nil,
                availability: [IntervalsAvailabilityDay]? = nil) {
        self.wellness = wellness; self.heightCm = heightCm; self.measurementPreference = measurementPreference
        self.availability = availability
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        wellness = try c.decodeIfPresent([WellnessUpdate].self, forKey: .wellness) ?? []
        heightCm = try c.decodeIfPresent(Double.self, forKey: .heightCm)
        measurementPreference = try c.decodeIfPresent(String.self, forKey: .measurementPreference)
        availability = try c.decodeIfPresent([IntervalsAvailabilityDay].self, forKey: .availability)
    }

    public var isEmpty: Bool { wellness.isEmpty && heightCm == nil && measurementPreference == nil && availability == nil }

    public mutating func enqueue(_ update: WellnessUpdate) {
        guard !update.isEmpty else { return }
        if let i = wellness.firstIndex(where: { $0.day == update.day }) {
            wellness[i] = wellness[i].merging(update)
        } else {
            wellness.append(update)
            wellness.sort { $0.day < $1.day }
        }
    }

    public func pendingWellness(on day: Day) -> WellnessUpdate? { wellness.first { $0.day == day } }

    /// Drops exactly what `flush` confirmed. A value changed again while the write was in flight stays.
    public mutating func removeConfirmed(_ result: IntervalsOutboxFlush) {
        wellness.removeAll { result.wellness.contains($0) }
        if let v = result.heightCm, v == heightCm { heightCm = nil }
        if let v = result.measurementPreference, v == measurementPreference { measurementPreference = nil }
        if let v = result.availability, v == availability { availability = nil }
    }

    /// Drops wellness updates Intervals already shows (after a read), so nothing is resent needlessly.
    public mutating func dropReflected(in days: [WellnessDay]) {
        let byDay = Dictionary(days.map { ($0.day, $0) }, uniquingKeysWith: { $1 })
        wellness.removeAll { update in byDay[update.day].map(update.isReflected(in:)) ?? false }
    }
}

/// What one `flush` confirmed, and what it could not send.
public struct IntervalsOutboxFlush: Equatable, Sendable {
    public var wellness: [WellnessUpdate] = []
    public var ftp: Int?
    public var heightCm: Double?
    public var measurementPreference: String?
    public var availability: [IntervalsAvailabilityDay]?
    /// Writes held back because the token lacks the scope; the athlete has to reconnect.
    public var missingScopes: Set<IntervalsScope> = []
    public var failure: String?

    public init() {}
}

public extension IntervalsClient {
    /// Sends everything queued, by area, so one failing write never blocks the others. Writes whose scope
    /// the token lacks stay queued and are reported in `missingScopes`.
    func flush(_ outbox: IntervalsOutbox, ftp: Int?, athlete: AthleteProfile?, today: Day) async -> IntervalsOutboxFlush {
        var result = IntervalsOutboxFlush()
        func fail(_ area: String, _ error: Error) {
            if result.failure == nil { result.failure = "Intervals \(area): \(error.localizedDescription)" }
        }

        if !outbox.wellness.isEmpty {
            if credential.grants(.wellnessWrite) {
                // Today's weight goes on its own with `localDate`, which also updates the athlete's current
                // weight in Intervals settings. The rest go in batches.
                let single = outbox.wellness.filter { $0.day == today && $0.weightKg != nil }
                let batched = outbox.wellness.filter { !($0.day == today && $0.weightKg != nil) }
                for update in single {
                    do { try await updateWellness(update, localDate: today); result.wellness.append(update) }
                    catch { fail("wellness", error) }
                }
                var start = 0
                while start < batched.count {
                    let chunk = Array(batched[start..<min(start + 50, batched.count)])
                    do { try await updateWellness(chunk); result.wellness += chunk }
                    catch { fail("wellness", error); break }
                    start += 50
                }
            } else { result.missingScopes.insert(.wellnessWrite) }
        }

        let settingsPending = ftp != nil || outbox.heightCm != nil || outbox.measurementPreference != nil || outbox.availability != nil
        if settingsPending && !credential.grants(.settingsWrite) {
            result.missingScopes.insert(.settingsWrite)
            return result
        }
        if let ftp {
            if IntervalsAthleteFields.holds(ftp: ftp, athlete: athlete) {
                result.ftp = ftp
            } else {
                do { try await updateRideFTP(ftp, athlete: athlete); result.ftp = ftp } catch { fail("FTP", error) }
            }
        }
        if outbox.heightCm != nil || outbox.measurementPreference != nil || outbox.availability != nil {
            do {
                try await updateAthlete(heightCm: outbox.heightCm, measurementPreference: outbox.measurementPreference,
                                        trainingAvailability: outbox.availability)
                result.heightCm = outbox.heightCm
                result.measurementPreference = outbox.measurementPreference
                result.availability = outbox.availability
            } catch { fail("profile", error) }
        }
        return result
    }

    /// Brings Cadencia's other calendar entries (goal event, time away, other training) in line with
    /// `desired`, and returns the base to store. A failed read writes nothing; a failed write throws, and the
    /// next pass resumes safely because every step is matched by external id first.
    func syncCalendarEntries(_ desired: [CalendarEntry], base: [String: CalendarEntryBase], today: Day) async throws -> [String: CalendarEntryBase] {
        var remote: [IntervalsEvent] = []
        if let window = CalendarSync.window(for: desired) {
            remote = try await events(oldest: window.lowerBound, newest: window.upperBound)
        }
        let plan = CalendarSync.plan(desired: desired, remote: remote, base: base, today: today)
        var newBase = plan.base
        if !plan.deletions.isEmpty {
            _ = try await deleteEvents(plan.deletions)
        }
        for update in plan.updates {
            let event = try await updateCalendarEntry(update.entry, eventID: update.eventID)
            newBase[update.entry.externalID]?.eventID = event.id
        }
        if !plan.creates.isEmpty {
            let created = try await createCalendarEntries(plan.creates)
            for event in created {
                if let id = event.external_id, newBase[id] != nil { newBase[id]?.eventID = event.id }
            }
        }
        return newBase
    }
}

// MARK: - Reading back

public enum IntervalsReadBack {
    /// The feedback cache after a wellness read over `range`: Intervals' values for every day read (a field
    /// cleared there is cleared here), with each day's queued update laid on top. `rpe` lives on the activity
    /// and is kept from the cache. Days outside the read keep their cached feedback.
    public static func feedback(cached: [String: SubjectiveFeedback], remote: [WellnessDay], range: ClosedRange<Day>,
                                pending: [WellnessUpdate]) -> [String: SubjectiveFeedback] {
        var result = cached.filter { key, _ in Day(iso: key).map { !range.contains($0) } ?? false }
        let remoteByDay = Dictionary(remote.map { ($0.day, $0) }, uniquingKeysWith: { $1 })
        var days = Set(remote.map(\.day).filter(range.contains))
        days.formUnion(cached.keys.compactMap(Day.init(iso:)).filter(range.contains))
        for day in days {
            let previous = cached[day.iso]
            if let wellness = remoteByDay[day], let f = SubjectiveFeedback(wellness: wellness, cached: previous) {
                result[day.iso] = f
            } else if let rpe = previous?.rpe {
                result[day.iso] = SubjectiveFeedback(day: day, rpe: rpe)
            }
        }
        for update in pending {
            let base = result[update.day.iso] ?? SubjectiveFeedback(day: update.day)
            let merged = base.applying(update)
            if merged != SubjectiveFeedback(day: update.day) { result[update.day.iso] = merged }
        }
        return result
    }

    /// Subjective fields of a cached day replaced by Intervals' (a cleared field is cleared), other fields
    /// merged as usual (Apple Health may hold values Intervals does not).
    public static func wellness(_ cached: WellnessDay?, remote: WellnessDay) -> WellnessDay {
        var merged = cached.map { $0.merging(remote) } ?? remote
        merged.soreness = remote.soreness
        merged.fatigue = remote.fatigue
        merged.sleepQuality = remote.sleepQuality
        merged.motivation = remote.motivation
        merged.mood = remote.mood
        merged.stress = remote.stress
        merged.injury = remote.injury
        merged.comments = remote.comments
        return merged
    }
}

// MARK: - One-time migration

/// Version 1 moves what older versions kept only on the phone into Intervals, once.
public enum IntervalsMigration {
    public static let version = 1

    /// The writes that bring Intervals up to date with what Cadencia kept locally. Wellness fields Intervals
    /// already has for a day are left alone, so nothing entered in Intervals is overwritten; settings are
    /// sent only where the local value is an explicit choice. Idempotent: running it twice queues the same
    /// absolute values.
    public static func outbox(feedback: [SubjectiveFeedback], wellness: [WellnessDay], measurements: CyclistMeasurements?,
                              athlete: AthleteProfile?, unitsMetric: Bool, availability: [IntervalsAvailabilityDay]?,
                              pendingWeight: WellnessUpdate?, existing: IntervalsOutbox = .init()) -> IntervalsOutbox {
        var outbox = existing
        let byDay = Dictionary(wellness.map { ($0.day, $0) }, uniquingKeysWith: { $1 })
        for f in feedback.sorted(by: { $0.day < $1.day }) {
            let update = WellnessUpdate(feedback: f).filling(missingIn: byDay[f.day])
            outbox.enqueue(update)
        }
        if let pendingWeight { outbox.enqueue(pendingWeight) }
        if outbox.heightCm == nil, let height = measurements?.height, height.source != .intervals,
           athlete.map({ $0.heightCm.map { abs($0 - height.value) >= 0.5 } ?? true }) ?? true {
            outbox.heightCm = height.value
        }
        // Metric is the default, not a choice; only an explicit switch to imperial is sent.
        if outbox.measurementPreference == nil, !unitsMetric, IntervalsAthleteFields.isMetric(athlete?.measurementPreference) != false {
            outbox.measurementPreference = IntervalsAthleteFields.imperial
        }
        if outbox.availability == nil, let availability, athlete?.trainingAvailability != availability {
            outbox.availability = availability
        }
        return outbox
    }
}

public extension WellnessUpdate {
    /// Only the fields `day` (Intervals' record) does not have yet.
    func filling(missingIn day: WellnessDay?) -> WellnessUpdate {
        guard let day else { return self }
        var u = self
        if day.weightKg != nil { u.weightKg = nil }
        if day.soreness != nil || day.fatigue != nil { u.soreness = nil; u.fatigue = nil }
        if day.sleepQuality != nil { u.sleepQuality = nil }
        if day.motivation != nil { u.motivation = nil }
        if day.mood != nil { u.mood = nil }
        if day.stress != nil { u.stress = nil }
        if day.injury != nil { u.injury = nil }
        if day.comments != nil { u.comments = nil }
        if day.hrvMs != nil { u.hrvMs = nil }
        if day.restingHR != nil { u.restingHR = nil }
        if day.sleepSeconds != nil { u.sleepSeconds = nil }
        return u
    }
}
