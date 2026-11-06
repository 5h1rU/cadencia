import Foundation

/// A Cadencia-owned Intervals calendar event other than a planned ride: the plan's goal event (`RACE_A/B/C`),
/// time away (`HOLIDAY`, `SICK`, `INJURED`) and other training such as gym or CrossFit (`WORKOUT`).
///
/// Each entry has a deterministic `external_id`, so a reinstall or a retried write lands on the same event.
/// `CalendarSync` keeps, per external id, the fingerprint of what Cadencia last wrote (`CalendarEntryBase`):
/// an entry whose local definition still matches that fingerprint is not written again, so whatever the
/// athlete changed or deleted in Intervals stays that way.
public struct CalendarEntry: Codable, Equatable, Sendable {
    public static let racePrefix = "cadencia-race-"
    public static let awayPrefix = "cadencia-away-"
    public static let otherPrefix = "cadencia-other-"
    /// Marks time away read from an event the athlete created in Intervals. Never written back.
    public static let foreignPrefix = "intervals-event-"
    /// Tag on a priority day that is not ridden as a race (a group ride or gran fondo).
    public static let notRaceTag = "group-ride"

    public static func isEntryIdentifier(_ id: String) -> Bool {
        [racePrefix, awayPrefix, otherPrefix].contains { id.hasPrefix($0) }
    }

    public var externalID: String
    public var category: String
    public var start: Day
    /// Inclusive last day, for multi-day entries.
    public var end: Day?
    public var name: String
    public var description: String?
    public var type: String?
    public var movingTime: Int?
    /// Metres.
    public var distance: Double?
    public var tags: [String]?
    public var trainingAvailability: String?

    public var lastDay: Day { end ?? start }

    /// Stable across launches and devices: a hash of the canonical JSON.
    public var fingerprint: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(self)) ?? Data()
        return SHA256.hash(Array(data)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// The event JSON for `POST /events/bulk` or `PUT /events/{id}`.
    public var body: [String: Any] {
        var b: [String: Any] = [
            "category": category,
            "start_date_local": "\(start.iso)T00:00:00",
            "name": name,
            "external_id": externalID,
            "uid": externalID,
        ]
        if let end, end != start { b["end_date_local"] = "\(end.iso)T00:00:00" }
        if let description { b["description"] = description }
        if let type { b["type"] = type }
        if let movingTime { b["moving_time"] = movingTime }
        if let distance { b["distance"] = distance }
        if let tags { b["tags"] = tags }
        if let trainingAvailability { b["training_availability"] = trainingAvailability }
        return b
    }

    /// Whether `event` already shows exactly this entry.
    public func isReflected(by event: IntervalsEvent) -> Bool {
        event.external_id == externalID && event.category == category && event.day == start && event.endDay == lastDay
            && event.name == name && (description == nil || event.description == description)
            && (type == nil || event.type == type) && (movingTime == nil || event.moving_time == movingTime)
            && (distance == nil || event.distance.map { abs($0 - distance!) < 1 } == true)
            && (tags == nil || Set(event.tags ?? []) == Set(tags!))
            && (trainingAvailability == nil || event.training_availability == trainingAvailability)
    }

    // MARK: Builders

    /// The plan's goal event. `description` is the objective; the course and logistics stay in Cadencia.
    /// `minutes` is the expected duration (the race-day session's target), so Intervals can plan around it.
    public static func race(_ event: TrainingEvent, minutes: Int? = nil) -> CalendarEntry {
        CalendarEntry(externalID: event.externalID ?? racePrefix + event.day.iso, category: "RACE_" + event.priority.rawValue.uppercased(),
                      start: event.day, name: event.name, description: event.objective.isEmpty ? nil : event.objective,
                      type: "Ride", movingTime: minutes.map { $0 * 60 }, distance: event.distanceKm.map { ($0 * 1000).rounded() },
                      tags: event.isRace ? nil : [notRaceTag])
    }

    /// The race-day session the goal event entry stands for. The ride mirror leaves it to this entry, so
    /// race day is one event in Intervals, not two.
    public static func raceDaySession(_ session: PlannedSession, in plan: TrainingPlan?) -> Bool {
        guard let event = plan?.event else { return false }
        return session.day == event.day && (session.kind == .race || session.kind == .groupRide)
    }

    public static func raceEntry(in plan: TrainingPlan) -> CalendarEntry? {
        guard let event = plan.event else { return nil }
        return race(event, minutes: plan.sessions.first { raceDaySession($0, in: plan) }?.targetMinutes)
    }

    public static func timeAway(_ period: PlanConsultation.TimeAway) -> CalendarEntry? {
        guard period.externalID?.hasPrefix(foreignPrefix) != true else { return nil }
        let kind = period.resolvedKind
        let reason = period.reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback: String
        switch kind {
        case .holiday: fallback = "Holiday"
        case .sick: fallback = "Sick"
        case .injured: fallback = "Injured"
        }
        return CalendarEntry(externalID: period.externalID ?? awayPrefix + period.start.iso + "-" + period.end.iso,
                             category: kind.rawValue, start: period.start, end: period.end,
                             name: reason.isEmpty ? fallback : String(reason.prefix(120)), description: reason.isEmpty ? nil : reason,
                             trainingAvailability: IntervalsAvailabilityDay.Level.unavailable.rawValue)
    }

    /// One dated occurrence of a recurring non-cycling activity.
    public static func otherTraining(_ activity: PlanConsultation.OtherTraining, on day: Day) -> CalendarEntry {
        CalendarEntry(externalID: otherPrefix + slug(activity.name) + "-" + day.iso, category: "WORKOUT", start: day,
                      name: activity.name, description: "Intensity: \(activity.intensity.rawValue) · \(activity.minutes) min",
                      type: sportType(for: activity.name), movingTime: activity.minutes * 60,
                      tags: ["intensity-" + activity.intensity.rawValue])
    }

    /// Intervals activity type for a named activity: gym → WeightTraining, CrossFit → Crossfit.
    public static func sportType(for name: String) -> String {
        let n = name.lowercased()
        if n.contains("crossfit") || n.contains("cross fit") { return "Crossfit" }
        if n.contains("yoga") { return "Yoga" }
        if n.contains("pilates") { return "Pilates" }
        if n.contains("hiit") { return "HighIntensityIntervalTraining" }
        if n.contains("swim") || n.contains("nata") || n.contains("piscina") { return "Swim" }
        if n.contains("run") || n.contains("correr") || n.contains("carrera") || n.contains("running") { return "Run" }
        return "WeightTraining"
    }

    static func slug(_ name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let parts = folded.lowercased().split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }
        let joined = parts.joined(separator: "-")
        return joined.isEmpty ? "activity" : String(joined.prefix(40))
    }

    /// Everything the active plan puts on the calendar from `today`: the goal event, time away that has not
    /// ended, and other training over the next `horizonDays` (a rolling window, like the ride mirror).
    public static func entries(for plan: TrainingPlan?, today: Day, horizonDays: Int = 28) -> [CalendarEntry] {
        guard let plan, plan.isActive else { return [] }
        var result: [CalendarEntry] = []
        if let entry = raceEntry(in: plan), entry.start >= today { result.append(entry) }
        guard let details = plan.consultation else { return result }
        result += details.timeAway.filter { $0.end >= today }.compactMap(timeAway)
        let first = max(today, plan.startDay), last = min(plan.endDay, today.adding(days: horizonDays - 1))
        if first <= last {
            for offset in 0...first.days(until: last) {
                let day = first.adding(days: offset)
                guard !details.isUnavailable(day) else { continue }
                for activity in details.otherTraining where activity.weekdays.contains(day.weekday()) {
                    result.append(otherTraining(activity, on: day))
                }
            }
        }
        // Two activities with the same name on one day would share an id; keep the first.
        var seen = Set<String>()
        return result.filter { seen.insert($0.externalID).inserted }
    }
}

/// What Cadencia last wrote for one entry.
public struct CalendarEntryBase: Codable, Equatable, Sendable {
    public var fingerprint: String
    public var eventID: Int?
    public var lastDay: Day
    public init(fingerprint: String, eventID: Int?, lastDay: Day) {
        self.fingerprint = fingerprint; self.eventID = eventID; self.lastDay = lastDay
    }
}

public enum CalendarSync {
    public struct Update: Equatable, Sendable { public var eventID: Int; public var entry: CalendarEntry }
    public struct Deletion: Codable, Equatable, Sendable {
        public var externalID: String?
        public var eventID: Int?
        public init(externalID: String?, eventID: Int?) { self.externalID = externalID; self.eventID = eventID }
    }

    public struct Plan: Equatable, Sendable {
        public var creates: [CalendarEntry] = []
        public var updates: [Update] = []
        public var deletions: [Deletion] = []
        /// The base once every write above has succeeded.
        public var base: [String: CalendarEntryBase] = [:]
        public var isEmpty: Bool { creates.isEmpty && updates.isEmpty && deletions.isEmpty }
    }

    /// The days to read before planning: every desired entry.
    public static func window(for desired: [CalendarEntry]) -> ClosedRange<Day>? {
        guard let first = desired.map(\.start).min(), let last = desired.map(\.lastDay).max() else { return nil }
        return first...last
    }

    /// Three-way plan between what Cadencia wants (`desired`), what Intervals has (`remote`, read over
    /// `window(for: desired)`) and what Cadencia last wrote (`base`).
    ///
    /// - Unchanged locally since the last write: nothing is written. The athlete's edits or deletion stand.
    /// - New or changed locally: created, or updated by server id when Intervals already has the external id.
    /// - In the base but no longer wanted: deleted, unless it is already in the past (history stays).
    /// - Extra copies of one external id (a lost create response): all but the newest are deleted.
    public static func plan(desired: [CalendarEntry], remote: [IntervalsEvent], base: [String: CalendarEntryBase], today: Day) -> Plan {
        var plan = Plan()
        let byExternalID = Dictionary(grouping: remote.filter { $0.external_id.map(CalendarEntry.isEntryIdentifier) == true },
                                      by: { $0.external_id! })
        let wanted = Set(desired.map(\.externalID))
        for entry in desired {
            let copies = (byExternalID[entry.externalID] ?? []).sorted { $0.id > $1.id }
            let existing = copies.first
            for extra in copies.dropFirst() { plan.deletions.append(.init(externalID: nil, eventID: extra.id)) }
            let previous = base[entry.externalID]
            let record = CalendarEntryBase(fingerprint: entry.fingerprint, eventID: existing?.id ?? previous?.eventID, lastDay: entry.lastDay)
            if previous?.fingerprint == entry.fingerprint {
                plan.base[entry.externalID] = record
            } else if let existing {
                if !entry.isReflected(by: existing) { plan.updates.append(.init(eventID: existing.id, entry: entry)) }
                plan.base[entry.externalID] = record
            } else {
                plan.creates.append(entry)
                plan.base[entry.externalID] = record
            }
        }
        for (externalID, previous) in base where !wanted.contains(externalID) {
            // Past entries are history: forget them without touching the calendar.
            guard previous.lastDay >= today else { continue }
            plan.deletions.append(.init(externalID: externalID, eventID: previous.eventID))
        }
        plan.deletions.sort { ($0.externalID ?? "", $0.eventID ?? 0) < ($1.externalID ?? "", $1.eventID ?? 0) }
        return plan
    }

    /// Pins the external ids of the plan's goal event and time away, so later date edits (here or in
    /// Intervals) keep addressing the same calendar entry.
    public static func pinIdentifiers(in plan: inout TrainingPlan) {
        if let event = plan.event, event.externalID == nil { plan.event?.externalID = CalendarEntry.race(event).externalID }
        guard var details = plan.consultation else { return }
        for i in details.timeAway.indices where details.timeAway[i].externalID == nil {
            details.timeAway[i].externalID = CalendarEntry.timeAway(details.timeAway[i])?.externalID
        }
        plan.consultation = details
    }

    // MARK: Reading back

    /// Folds what the athlete changed in Intervals into the plan: the goal event's name, date, distance,
    /// objective and priority, and the dates, reason and kind of time away; time away deleted in Intervals
    /// goes. Events the athlete created in Intervals as unavailable HOLIDAY/SICK/INJURED days become
    /// read-only time away. Only entries Cadencia has not changed since its last write are touched, and
    /// only those starting within `window`, the range `events` was read over (Intervals lists events by
    /// start date, so a period that began earlier is not in the read). Returns whether the plan changed.
    @discardableResult
    public static func adopt(_ events: [IntervalsEvent], window: ClosedRange<Day>, into plan: inout TrainingPlan,
                             base: [String: CalendarEntryBase]) -> Bool {
        let before = plan
        func remote(_ id: String) -> IntervalsEvent? {
            events.filter { $0.external_id == id }.max { $0.id < $1.id }
        }
        func unchanged(_ entry: CalendarEntry) -> Bool { base[entry.externalID]?.fingerprint == entry.fingerprint }

        if var event = plan.event, window.contains(event.day), let entry = CalendarEntry.raceEntry(in: plan) {
            if unchanged(entry), let r = remote(entry.externalID), !entry.isReflected(by: r), let edited = r.trainingEvent {
                event.externalID = entry.externalID
                event.name = edited.name
                event.day = edited.day
                event.priority = edited.priority
                event.objective = edited.objective
                event.isRace = edited.isRace
                if r.distance != nil { event.distanceKm = edited.distanceKm }
                plan.event = event
            }
        }

        if var details = plan.consultation {
            var periods: [PlanConsultation.TimeAway] = []
            for period in details.timeAway {
                if period.externalID?.hasPrefix(CalendarEntry.foreignPrefix) == true {
                    // Re-read below; Intervals is the only source of these.
                    if !window.contains(period.start) { periods.append(period) }
                    continue
                }
                guard let entry = CalendarEntry.timeAway(period), unchanged(entry),
                      window.contains(period.start) else { periods.append(period); continue }
                guard let r = remote(entry.externalID) else { continue } // deleted in Intervals
                guard !entry.isReflected(by: r), let start = r.day else { periods.append(period); continue }
                let reason = (r.description ?? r.name ?? period.reason)
                periods.append(.init(start: start, end: max(start, r.endDay ?? start), reason: reason,
                                     kind: r.category.flatMap(PlanConsultation.TimeAway.Kind.init(rawValue:)) ?? period.kind,
                                     externalID: entry.externalID))
            }
            let planRange = plan.startDay...plan.endDay
            for r in events where r.external_id.map(CalendarEntry.isEntryIdentifier) != true && !r.isCadenciaOwned {
                guard let kind = r.category.flatMap(PlanConsultation.TimeAway.Kind.init(rawValue:)), let start = r.day,
                      r.training_availability == nil || r.training_availability == IntervalsAvailabilityDay.Level.unavailable.rawValue
                else { continue }
                let end = max(start, r.endDay ?? start)
                guard window.contains(start), planRange.overlaps(start...end) else { continue }
                periods.append(.init(start: start, end: end, reason: r.name ?? r.description ?? "", kind: kind,
                                     externalID: CalendarEntry.foreignPrefix + String(r.id)))
            }
            details.timeAway = periods.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
            plan.consultation = details
        }
        return plan != before
    }
}
