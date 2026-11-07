import XCTest
@testable import CadenciaCore

/// Intervals.icu is the source of truth for everything it has a native field for; Cadencia keeps a cache.
/// One group of tests per correspondence.

private func json(_ request: HTTPRequest?) throws -> Any {
    try JSONSerialization.jsonObject(with: XCTUnwrap(request?.body))
}

private func query(_ request: HTTPRequest?) -> [String: String] {
    let items = request.flatMap { URLComponents(url: $0.url, resolvingAgainstBaseURL: false)?.queryItems } ?? []
    return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
}

private func events(_ text: String) throws -> [IntervalsEvent] {
    try JSONDecoder().decode([IntervalsEvent].self, from: Data(text.utf8))
}

private let monday = Day(year: 2026, month: 11, day: 2)

// MARK: - 1. Feedback → wellness

final class FeedbackWellnessTests: XCTestCase {
    func testFeedbackMapsOntoIntervalsScaleWhereOneIsGood() throws {
        let feedback = SubjectiveFeedback(day: monday, rpe: 7, legs: .heavy, sleepQuality: 5, motivation: 2, note: "Long day at work",
                                          mood: 2, stress: 3, injury: 1)
        let update = WellnessUpdate(feedback: feedback)
        XCTAssertEqual(update.soreness, 3, "heavy legs are sore legs")
        XCTAssertEqual(update.sleepQuality, 1, "great sleep is Intervals' 1")
        XCTAssertEqual(update.motivation, 4, "low motivation is Intervals' 4")
        XCTAssertEqual(update.comments, "Long day at work")
        XCTAssertEqual([update.mood, update.stress, update.injury], [2, 3, 1])
        let body = update.body
        XCTAssertNil(body["rpe"], "RPE belongs to the activity (icu_rpe), not the wellness record")
        XCTAssertNil(body["icu_rpe"])
        XCTAssertEqual(body["id"] as? String, "2026-11-02")
        XCTAssertEqual(Set(body.keys), ["id", "soreness", "sleepQuality", "motivation", "comments", "mood", "stress", "injury"])
    }

    func testScalesRoundTripTheDirection() {
        XCTAssertEqual(IntervalsWellnessScale.soreness(for: .fresh), 1)
        XCTAssertEqual(IntervalsWellnessScale.soreness(for: .ok), 2)
        for legs in [SubjectiveFeedback.Legs.fresh, .ok, .heavy] {
            XCTAssertEqual(IntervalsWellnessScale.legs(soreness: IntervalsWellnessScale.soreness(for: legs), fatigue: nil), legs)
        }
        XCTAssertEqual(IntervalsWellnessScale.legs(soreness: 4, fatigue: nil), .heavy)
        XCTAssertEqual(IntervalsWellnessScale.legs(soreness: nil, fatigue: 1), .fresh, "fatigue stands in when only it was recorded")
        for value in 3...5 {
            XCTAssertEqual(IntervalsWellnessScale.fivePoint(fromIntervals: IntervalsWellnessScale.intervals(fromFivePoint: value)), value)
        }
        XCTAssertEqual(IntervalsWellnessScale.intervals(fromFivePoint: 1), 4, "Intervals has four steps; the bottom two share one")
    }

    func testWellnessDecodesSubjectiveFieldsAndIgnoresUnsetValues() async throws {
        let body = #"[{"id":"2026-11-02","soreness":3,"fatigue":-1,"sleepQuality":1,"motivation":2,"mood":4,"stress":2,"injury":1,"comments":"Tired"}]"#
        let t = FakeTransport(responses: [HTTPResponse(status: 200, body: Data(body.utf8))])
        let days = try await IntervalsClient(transport: t, credential: IntervalsCredential(accessToken: "k")).wellness(oldest: monday, newest: monday)
        let day = try XCTUnwrap(days.first)
        XCTAssertNil(day.fatigue, "-1 is Intervals' unset value")
        let feedback = try XCTUnwrap(SubjectiveFeedback(wellness: day))
        XCTAssertEqual(feedback.legs, .heavy)
        XCTAssertEqual(feedback.sleepQuality, 5)
        XCTAssertEqual(feedback.motivation, 4)
        XCTAssertEqual(feedback.note, "Tired")
        XCTAssertEqual([feedback.mood, feedback.stress, feedback.injury], [4, 2, 1])
    }

    func testSingleDayWriteUsesPutWellnessAndLocalDateForTodaysWeight() async throws {
        let t = FakeTransport()
        let client = IntervalsClient(transport: t, credential: IntervalsCredential(accessToken: "k"))
        try await client.updateWellness(WellnessUpdate(day: monday, weightKg: 71.4), localDate: monday)
        XCTAssertEqual(t.requests[0].method, .put)
        XCTAssertEqual(t.requests[0].url.path, "/api/v1/athlete/0/wellness/2026-11-02")
        XCTAssertEqual(query(t.requests[0])["localDate"], "2026-11-02", "also updates the athlete's current weight")
        XCTAssertEqual((try json(t.requests[0]) as? [String: Any])?["weight"] as? Double, 71.4)
    }

    func testSeveralDaysGoInOneBulkRequest() async throws {
        let t = FakeTransport()
        let updates = [WellnessUpdate(day: monday, soreness: 2), WellnessUpdate(day: monday.adding(days: 1), motivation: 1)]
        try await IntervalsClient(transport: t, credential: IntervalsCredential(accessToken: "k")).updateWellness(updates)
        XCTAssertEqual(t.requests.count, 1)
        XCTAssertEqual(t.requests[0].url.path, "/api/v1/athlete/0/wellness-bulk")
        let rows = try XCTUnwrap(json(t.requests[0]) as? [[String: Any]])
        XCTAssertEqual(rows.map { $0["id"] as? String }, ["2026-11-02", "2026-11-03"])
    }

    func testRefreshLetsIntervalsWinIncludingClearedFieldsButKeepsPendingEditsAndRPE() {
        let tuesday = monday.adding(days: 1)
        let cached: [String: SubjectiveFeedback] = [
            monday.iso: .init(day: monday, rpe: 6, legs: .heavy, motivation: 4),
            tuesday.iso: .init(day: tuesday, legs: .fresh),
            "2026-10-01": .init(day: Day(year: 2026, month: 10, day: 1), legs: .ok),
        ]
        // Monday was edited in Intervals: soreness cleared, motivation changed. Tuesday's edit is still queued.
        let remote = [WellnessDay(day: monday, motivation: 1), WellnessDay(day: tuesday, soreness: 3)]
        let pending = [WellnessUpdate(day: tuesday, soreness: 1)]
        let result = IntervalsReadBack.feedback(cached: cached, remote: remote, range: monday...tuesday, pending: pending)
        XCTAssertNil(result[monday.iso]?.legs, "cleared in Intervals, cleared here")
        XCTAssertEqual(result[monday.iso]?.motivation, 5)
        XCTAssertEqual(result[monday.iso]?.rpe, 6, "RPE lives on the activity and is kept")
        XCTAssertEqual(result[tuesday.iso]?.legs, .fresh, "an unsent local edit survives the refresh")
        XCTAssertEqual(result["2026-10-01"]?.legs, .ok, "days outside the read keep their cache")
    }

    func testIntervalsReplacesCachedSubjectiveFieldsButKeepsHealthValues() {
        let cached = WellnessDay(day: monday, hrvMs: 52, soreness: 3, comments: "old")
        let merged = IntervalsReadBack.wellness(cached, remote: WellnessDay(day: monday, ctl: 60))
        XCTAssertEqual(merged.hrvMs, 52)
        XCTAssertEqual(merged.ctl, 60)
        XCTAssertNil(merged.soreness)
        XCTAssertNil(merged.comments)
    }

    func testOutboxMergesEditsOfOneDayAndDropsOnlyWhatWasConfirmed() {
        var outbox = IntervalsOutbox()
        outbox.enqueue(WellnessUpdate(day: monday, soreness: 2))
        outbox.enqueue(WellnessUpdate(day: monday, motivation: 1))
        XCTAssertEqual(outbox.wellness, [WellnessUpdate(day: monday, soreness: 2, motivation: 1)])
        var sent = IntervalsOutboxFlush()
        sent.wellness = outbox.wellness
        outbox.enqueue(WellnessUpdate(day: monday, soreness: 3)) // edited while the write was in flight
        outbox.removeConfirmed(sent)
        XCTAssertEqual(outbox.wellness.first?.soreness, 3, "the newer edit is still sent")
        outbox.dropReflected(in: [WellnessDay(day: monday, soreness: 3, motivation: 1)])
        XCTAssertTrue(outbox.isEmpty)
    }

}

// MARK: - 2. FTP → sport settings; estimate from Intervals' eFTP

final class FTPSourceOfTruthTests: XCTestCase {
    func testAcceptedFTPWritesRideSportSettingsAndIndoorFTPWhenUsed() async throws {
        let t = FakeTransport()
        let client = IntervalsClient(transport: t, credential: IntervalsCredential(accessToken: "k"))
        let athlete = AthleteProfile(id: "i1", name: "F", ftp: 240, indoorFTP: 232)
        let result = await client.flush(IntervalsOutbox(), ftp: 251, athlete: athlete, today: monday)
        XCTAssertEqual(result.ftp, 251)
        XCTAssertEqual(t.requests.first?.method, .put)
        XCTAssertEqual(t.requests.first?.url.path, "/api/v1/athlete/0/sport-settings/Ride")
        let body = try XCTUnwrap(json(t.requests.first) as? [String: Int])
        XCTAssertEqual(body, ["ftp": 251, "indoor_ftp": 251], "Cadencia's working FTP is the indoor one when it exists")
        XCTAssertEqual(IntervalsAthleteFields.rideFTPBody(ftp: 251, athlete: AthleteProfile(id: "i1", name: "F", ftp: 240)) as? [String: Int], ["ftp": 251])
        XCTAssertEqual(IntervalsAthleteFields.applying(ftp: 251, to: athlete).workingFTP, 251)
    }

    func testFTPIntervalsAlreadyHoldsIsConfirmedWithoutAWrite() async {
        let t = FakeTransport()
        let result = await IntervalsClient(transport: t, credential: IntervalsCredential(accessToken: "k"))
            .flush(IntervalsOutbox(), ftp: 240, athlete: AthleteProfile(id: "i1", name: "F", ftp: 240), today: monday)
        XCTAssertEqual(result.ftp, 240)
        XCTAssertTrue(t.requests.isEmpty)
    }

    func testEstimatePrefersIntervalsRollingFTPOverLocalHeuristics() throws {
        let json = #"[{"id":"i1","type":"Ride","start_date_local":"2026-10-30T08:00:00","icu_rolling_ftp":247,"icu_pm_ftp":262,"compliance":91.5,"paired_event_id":7}]"#
        let activities = try JSONDecoder().decode([ActivityDTO].self, from: Data(json.utf8)).compactMap(\.model)
        XCTAssertEqual(activities[0].rollingFTP, 247)
        XCTAssertEqual(activities[0].compliance, 91.5)
        let eftp = FTPEstimator.intervalsEFTP(activities: activities, wellness: [WellnessDay(day: monday, estimatedFTP: 239.6)], today: monday)
        XCTAssertEqual(eftp, 247, "the rolling FTP, not the single-ride icu_pm_ftp")
        XCTAssertEqual(FTPEstimator.intervalsEFTP(activities: [], wellness: [WellnessDay(day: monday, estimatedFTP: 239.6)], today: monday), 240)
        let curve = [PowerCurvePoint(seconds: 1200, watts: 300)]
        let estimate = try XCTUnwrap(FTPEstimator().estimate(curve: curve, sustainedEfforts: 3, intervalsEFTP: 247))
        XCTAssertEqual(estimate.watts, 247)
        XCTAssertEqual(estimate.basis, "Intervals.icu eFTP")
        XCTAssertEqual(estimate.confidence, .moderate)
        XCTAssertEqual(FTPEstimator().estimate(curve: curve, sustainedEfforts: 3, intervalsEFTP: nil)?.watts, 285, "local heuristic as fallback")
    }
}

// MARK: - 3. Measurements → wellness weight, athlete height

final class MeasurementsSourceOfTruthTests: XCTestCase {
    func testAthleteHeightIsReadInMetresAndWrittenInMetres() async throws {
        let t = FakeTransport(responses: [HTTPResponse(status: 200, body: Data(#"{"id":"i1","height":1.78,"measurement_preference":"feet"}"#.utf8))])
        let client = IntervalsClient(transport: t, credential: IntervalsCredential(accessToken: "k"))
        let athlete = try await client.athlete()
        XCTAssertEqual(athlete.heightCm, 178)
        XCTAssertEqual(athlete.measurementPreference, "feet")
        try await client.updateAthlete(heightCm: 181.5)
        XCTAssertEqual(t.requests[1].url.path, "/api/v1/athlete/0")
        XCTAssertEqual((try json(t.requests[1]) as? [String: Double])?["height"], 1.815)
    }

    func testTodaysWeightGoesWithLocalDateAndOtherDaysInBulk() async throws {
        let t = FakeTransport()
        let outbox = IntervalsOutbox(wellness: [WellnessUpdate(day: monday.adding(days: -1), soreness: 2),
                                                WellnessUpdate(day: monday, weightKg: 70.2)], heightCm: 179)
        let result = await IntervalsClient(transport: t, credential: IntervalsCredential(accessToken: "k")).flush(outbox, ftp: nil, athlete: nil, today: monday)
        XCTAssertEqual(t.requests.map(\.url.path), ["/api/v1/athlete/0/wellness/2026-11-02", "/api/v1/athlete/0/wellness/2026-11-01", "/api/v1/athlete/0"])
        XCTAssertEqual(query(t.requests[0])["localDate"], "2026-11-02")
        XCTAssertEqual(Set(result.wellness.map(\.day)), [monday, monday.adding(days: -1)])
        XCTAssertEqual(result.heightCm, 179)
    }
}

// MARK: - 4. Weekly availability → training_availability

final class AvailabilitySourceOfTruthTests: XCTestCase {
    func testWeeklyRidesBecomeSevenISODaysWithLimitsAndOtherSports() {
        // Cadencia weekdays: 1 = Sunday. Tuesday 60 min, Saturday 180 min, gym on Thursday.
        let availability = Availability(hoursPerWeek: 4, minutesByWeekday: [3: 60, 7: 180], longRideWeekday: 7)
        let days = IntervalsAvailability.days(from: availability, otherSports: [5: ["WeightTraining"]])
        XCTAssertEqual(days.map(\.day_of_week), Array(1...7), "ISO: 1 = Monday")
        XCTAssertEqual(days[1], IntervalsAvailabilityDay(dayOfWeek: 2, level: .limited, maxTrainingSeconds: 3600, sports: ["Ride", "VirtualRide"]))
        XCTAssertEqual(days[5].max_training_time, 10800)
        XCTAssertEqual(days[3], IntervalsAvailabilityDay(dayOfWeek: 4, level: .limited, sports: ["WeightTraining"]))
        XCTAssertEqual(days[6].training_availability, .unavailable, "Sunday has no riding")
        XCTAssertEqual(IntervalsAvailability.isoDay(fromWeekday: 1), 7)
        XCTAssertEqual(IntervalsAvailability.weekday(fromISODay: 1), 2)
    }

    func testIntervalsEditsCapOrRemoveDaysButNeverInventRiding() {
        let availability = Availability(hoursPerWeek: 4, minutesByWeekday: [3: 60, 7: 180], longRideWeekday: 7)
        let edited = IntervalsAvailability.applying([
            IntervalsAvailabilityDay(dayOfWeek: 2, level: .unavailable),
            IntervalsAvailabilityDay(dayOfWeek: 6, level: .limited, maxTrainingSeconds: 5400, sports: ["Ride"]),
            IntervalsAvailabilityDay(dayOfWeek: 7, level: .normal),
            IntervalsAvailabilityDay(dayOfWeek: 1, level: .normal),
        ], to: availability)
        XCTAssertEqual(edited.minutesByWeekday, [7: 90])
        XCTAssertEqual(edited.longRideWeekday, 7, "no Intervals field: stays Cadencia's")
        XCTAssertEqual(edited.hoursPerWeek, 1.5)
        let rides = IntervalsAvailability.applying(edited, to: [.init(weekday: 3, minutes: 60, kind: .threshold), .init(weekday: 7, minutes: 180, kind: .longRide)])
        XCTAssertEqual(rides, [.init(weekday: 7, minutes: 90, kind: .longRide)], "the session type stays local")
        let untouched = IntervalsAvailability.applying((1...7).map { IntervalsAvailabilityDay(dayOfWeek: $0, level: .normal) }, to: availability)
        XCTAssertEqual(untouched, availability, "an athlete who never set availability changes nothing")
    }

    func testAvailabilityIsDecodedAndWrittenOnTheAthlete() async throws {
        let athleteJSON = #"{"id":"i1","training_availability":[{"day_of_week":1,"training_availability":"LIMITED","max_training_time":3600,"can_train_sports":["Ride"]}]}"#
        let t = FakeTransport(responses: [HTTPResponse(status: 200, body: Data(athleteJSON.utf8))])
        let client = IntervalsClient(transport: t, credential: IntervalsCredential(accessToken: "k"))
        let athlete = try await client.athlete()
        XCTAssertEqual(athlete.trainingAvailability, [IntervalsAvailabilityDay(dayOfWeek: 1, level: .limited, maxTrainingSeconds: 3600, sports: ["Ride"])])
        try await client.updateAthlete(trainingAvailability: [IntervalsAvailabilityDay(dayOfWeek: 3, level: .unavailable)])
        let body = try XCTUnwrap(json(t.requests[1]) as? [String: Any])
        XCTAssertEqual(body["training_availability"] as? [[String: AnyHashable]], [["day_of_week": 3, "training_availability": "UNAVAILABLE"]])
    }
}

// MARK: - 5–7. Time away, other training and the goal event → calendar entries

final class CalendarEntryTests: XCTestCase {
    private func plan(event: TrainingEvent? = nil, timeAway: [PlanConsultation.TimeAway] = [],
                      other: [PlanConsultation.OtherTraining] = []) -> TrainingPlan {
        var plan = TrainingPlan(goal: .endurance, title: "P", startDay: monday, endDay: monday.adding(days: 55), event: event,
                                availability: .typical, phases: [], sessions: [], isActive: true)
        plan.consultation = .init(objective: "o", rationale: "r", weeklyRides: [], otherTraining: other, timeAway: timeAway)
        return plan
    }

    func testTimeAwayBecomesAnUnavailableHolidaySickOrInjuredEvent() throws {
        let away = PlanConsultation.TimeAway(start: monday, end: monday.adding(days: 4), reason: "Family trip, will be away")
        let entry = try XCTUnwrap(CalendarEntry.timeAway(away))
        XCTAssertEqual(entry.category, "HOLIDAY", "'will' is not 'ill'")
        XCTAssertEqual(entry.externalID, "cadencia-away-2026-11-02-2026-11-06")
        let body = entry.body
        XCTAssertEqual(body["end_date_local"] as? String, "2026-11-06T00:00:00")
        XCTAssertEqual(body["training_availability"] as? String, "UNAVAILABLE")
        XCTAssertEqual(CalendarEntry.timeAway(.init(start: monday, end: monday, reason: "Gripe"))?.category, "SICK")
        XCTAssertEqual(CalendarEntry.timeAway(.init(start: monday, end: monday, reason: "Knee injury"))?.category, "INJURED")
        XCTAssertNil(CalendarEntry.timeAway(.init(start: monday, end: monday, reason: "", externalID: "intervals-event-9")),
                     "periods the athlete entered in Intervals are never written back")
    }

    func testOtherTrainingBecomesDatedWorkoutsWithTypeIntensityAndStableIDs() {
        let gym = PlanConsultation.OtherTraining(name: "Gimnasio", weekdays: [3, 5], minutes: 45, intensity: .hard)
        let crossfit = PlanConsultation.OtherTraining(name: "CrossFit", weekdays: [2], minutes: 60, intensity: .moderate)
        let away = PlanConsultation.TimeAway(start: monday.adding(days: 7), end: monday.adding(days: 13), reason: "Holiday")
        let entries = CalendarEntry.entries(for: plan(timeAway: [away], other: [gym, crossfit]), today: monday, horizonDays: 14)
        let workouts = entries.filter { $0.category == "WORKOUT" }
        XCTAssertEqual(workouts.map(\.externalID), ["cadencia-other-crossfit-2026-11-02", "cadencia-other-gimnasio-2026-11-03", "cadencia-other-gimnasio-2026-11-05"],
                       "the second week is time away")
        XCTAssertEqual(workouts[0].type, "Crossfit")
        XCTAssertEqual(workouts[1].type, "WeightTraining")
        XCTAssertEqual(workouts[1].movingTime, 2700)
        XCTAssertEqual(workouts[1].tags, ["intensity-hard"])
        XCTAssertEqual(workouts[1].description, "Intensity: hard · 45 min")
        XCTAssertEqual(entries, CalendarEntry.entries(for: plan(timeAway: [away], other: [gym, crossfit]), today: monday, horizonDays: 14), "deterministic")
    }

    func testGoalEventBecomesARaceWithDistanceAndObjectiveAndReadsBack() throws {
        let event = TrainingEvent(name: "Gran Fondo", day: monday.adding(days: 40), distanceKm: 120, priority: .b, objective: "Finish strong")
        let entry = CalendarEntry.race(event)
        XCTAssertEqual(entry.category, "RACE_B")
        XCTAssertEqual(entry.distance, 120_000)
        XCTAssertEqual(entry.description, "Finish strong")
        XCTAssertEqual(entry.tags, ["group-ride"], "not ridden as a race")
        let read = try XCTUnwrap(events(#"[{"id":5,"category":"RACE_B","name":"Gran Fondo","start_date_local":"2026-12-12T00:00:00","distance":120000,"description":"Finish strong","tags":["group-ride"],"external_id":"cadencia-race-2026-12-12"}]"#)[0].trainingEvent)
        XCTAssertEqual(read.distanceKm, 120)
        XCTAssertFalse(read.isRace)
        XCTAssertEqual(read.priority, .b)
    }

    func testPlanWritesOnlyWhatChangedLocallyAndRespectsIntervalsEdits() throws {
        let a = CalendarEntry.otherTraining(.init(name: "Gym", weekdays: [2], minutes: 45, intensity: .easy), on: monday)
        let b = CalendarEntry.otherTraining(.init(name: "Gym", weekdays: [2], minutes: 45, intensity: .easy), on: monday.adding(days: 7))
        let c = CalendarEntry.otherTraining(.init(name: "Gym", weekdays: [2], minutes: 60, intensity: .easy), on: monday.adding(days: 14))
        let gone = "cadencia-other-yoga-2026-11-04"
        let past = "cadencia-other-yoga-2026-10-28"
        let base: [String: CalendarEntryBase] = [
            a.externalID: .init(fingerprint: a.fingerprint, eventID: 1, lastDay: a.start),   // unchanged, edited in Intervals
            b.externalID: .init(fingerprint: b.fingerprint, eventID: 2, lastDay: b.start),   // unchanged, deleted in Intervals
            c.externalID: .init(fingerprint: "old", eventID: 3, lastDay: c.start),           // changed here
            gone: .init(fingerprint: "x", eventID: 4, lastDay: monday.adding(days: 2)),
            past: .init(fingerprint: "x", eventID: 5, lastDay: monday.adding(days: -5)),
        ]
        let remote = try events("""
        [{"id":1,"external_id":"\(a.externalID)","category":"WORKOUT","name":"Gym (moved by athlete)","start_date_local":"2026-11-02T00:00:00"},
         {"id":3,"external_id":"\(c.externalID)","category":"WORKOUT","name":"Gym","start_date_local":"2026-11-16T00:00:00"},
         {"id":6,"external_id":"\(c.externalID)","category":"WORKOUT","name":"Gym","start_date_local":"2026-11-16T00:00:00"}]
        """)
        let new = CalendarEntry.otherTraining(.init(name: "Swim", weekdays: [2], minutes: 30, intensity: .easy), on: monday)
        let plan = CalendarSync.plan(desired: [a, b, c, new], remote: remote, base: base, today: monday)
        XCTAssertEqual(plan.creates, [new], "an entry the athlete deleted in Intervals is not recreated")
        XCTAssertEqual(plan.updates, [.init(eventID: 6, entry: c)], "the newest copy is updated")
        XCTAssertEqual(plan.deletions, [.init(externalID: nil, eventID: 3), .init(externalID: gone, eventID: 4)],
                       "the duplicate goes by id only; the retired entry by external id and id; the past one stays")
        XCTAssertNil(plan.base[past])
        XCTAssertEqual(plan.base[c.externalID]?.fingerprint, c.fingerprint)
    }

    func testSyncCreatesInOneBulkUpsertThenIsIdle() async throws {
        let entry = CalendarEntry.race(TrainingEvent(name: "Race", day: monday.adding(days: 10)))
        let created = #"[{"id":77,"external_id":"cadencia-race-2026-11-12","category":"RACE_A"}]"#
        let t = FakeTransport(responses: [HTTPResponse(status: 200, body: Data("[]".utf8)), HTTPResponse(status: 200, body: Data(created.utf8))])
        let client = IntervalsClient(transport: t, credential: IntervalsCredential(accessToken: "k"))
        let base = try await client.syncCalendarEntries([entry], base: [:], today: monday)
        XCTAssertEqual(t.requests.map(\.method), [.get, .post])
        XCTAssertEqual(t.requests[1].url.path, "/api/v1/athlete/0/events/bulk")
        XCTAssertEqual(query(t.requests[1])["upsert"], "true")
        XCTAssertEqual(base[entry.externalID], CalendarEntryBase(fingerprint: entry.fingerprint, eventID: 77, lastDay: entry.start))
        t.responses = [HTTPResponse(status: 200, body: Data("[]".utf8))]
        _ = try await client.syncCalendarEntries([entry], base: base, today: monday)
        XCTAssertEqual(t.requests.count, 3, "second pass only reads")
    }

    func testRetiredEntriesAreBulkDeletedByExternalIDAndKnownIDs() async throws {
        let t = FakeTransport(responses: [HTTPResponse(status: 200, body: Data(#"{"eventsDeleted":1}"#.utf8))])
        try await IntervalsClient(transport: t, credential: IntervalsCredential(accessToken: "k"))
            .deleteEvents([.init(externalID: "cadencia-ride-2026-11-02", eventID: 41), .init(externalID: nil, eventID: 12)])
        XCTAssertEqual(t.requests[0].url.path, "/api/v1/athlete/0/events/bulk-delete")
        let items = try XCTUnwrap(json(t.requests[0]) as? [[String: AnyHashable]])
        XCTAssertEqual(items, [["external_id": "cadencia-ride-2026-11-02"], ["id": 12], ["id": 41]],
                       "by external id for OAuth-created events, by id for API-key ones")
    }

    func testEditsInIntervalsFlowBackIntoThePlan() throws {
        var event = TrainingEvent(name: "Race", day: monday.adding(days: 10), objective: "Win")
        let away = PlanConsultation.TimeAway(start: monday.adding(days: 3), end: monday.adding(days: 5), reason: "Holiday")
        let deleted = PlanConsultation.TimeAway(start: monday.adding(days: 20), end: monday.adding(days: 21), reason: "Trip")
        var p = plan(event: event, timeAway: [away, deleted])
        CalendarSync.pinIdentifiers(in: &p)
        let entries = CalendarEntry.entries(for: p, today: monday)
        let base = Dictionary(uniqueKeysWithValues: entries.map { ($0.externalID, CalendarEntryBase(fingerprint: $0.fingerprint, eventID: nil, lastDay: $0.lastDay)) })
        let remote = try events("""
        [{"id":1,"external_id":"cadencia-race-2026-11-12","category":"RACE_A","name":"Race (new date)","start_date_local":"2026-11-14T00:00:00","description":"Win"},
         {"id":2,"external_id":"cadencia-away-2026-11-05-2026-11-07","category":"SICK","name":"Flu","description":"Flu","start_date_local":"2026-11-05T00:00:00","end_date_local":"2026-11-08T00:00:00"},
         {"id":3,"category":"INJURED","name":"Knee","start_date_local":"2026-11-30T00:00:00","end_date_local":"2026-12-02T00:00:00"},
         {"id":4,"category":"HOLIDAY","name":"Can ride a bit","training_availability":"LIMITED","start_date_local":"2026-11-25T00:00:00"}]
        """)
        XCTAssertTrue(CalendarSync.adopt(remote, window: monday...monday.adding(days: 42), into: &p, base: base))
        event = try XCTUnwrap(p.event)
        XCTAssertEqual(event.day, monday.adding(days: 12))
        XCTAssertEqual(event.name, "Race (new date)")
        XCTAssertEqual(event.externalID, "cadencia-race-2026-11-12", "a moved event keeps its calendar identity")
        let periods = try XCTUnwrap(p.consultation?.timeAway)
        XCTAssertEqual(periods.count, 2, "the trip deleted in Intervals is gone; LIMITED holidays are not time away")
        XCTAssertEqual(periods[0].kind, .sick)
        XCTAssertEqual(periods[0].end, monday.adding(days: 6))
        XCTAssertEqual(periods[1].externalID, "intervals-event-3")
        XCTAssertNil(CalendarEntry.timeAway(periods[1]), "read-only")
        XCTAssertEqual(CalendarEntry.entries(for: p, today: monday).first { $0.category == "SICK" }?.externalID,
                       "cadencia-away-2026-11-05-2026-11-07")
    }

    func testLocalChangesAreNotOverwrittenByTheCalendar() throws {
        let event = TrainingEvent(name: "Race", day: monday.adding(days: 10), objective: "Win")
        var p = plan(event: event)
        let stale = ["cadencia-race-2026-11-12": CalendarEntryBase(fingerprint: "older", eventID: 1, lastDay: monday)]
        let remote = try events(#"[{"id":1,"external_id":"cadencia-race-2026-11-12","category":"RACE_A","name":"Old name","start_date_local":"2026-11-12T00:00:00"}]"#)
        XCTAssertFalse(CalendarSync.adopt(remote, window: monday...monday.adding(days: 42), into: &p, base: stale))
    }
}

// MARK: - 8. Planned sessions

final class PlannedSessionNativeFieldTests: XCTestCase {
    func testUpsertWritesIndoorFTPTagsAndDayIdentity() async throws {
        var session = PlannedSession(day: monday, kind: .threshold, title: "Threshold", targetMinutes: 60, location: .indoor, prescriptionFTP: 236)
        let t = FakeTransport(responses: [HTTPResponse(status: 200, body: Data(#"{"id":9}"#.utf8))])
        _ = try await IntervalsClient(transport: t, credential: IntervalsCredential(accessToken: "k")).upsertPlannedWorkout(session, ftp: 250)
        var body = try XCTUnwrap(json(t.requests[0]) as? [String: Any])
        XCTAssertEqual(body["external_id"] as? String, "cadencia-ride-2026-11-02")
        XCTAssertEqual(body["indoor"] as? Bool, true)
        XCTAssertEqual(body["icu_ftp"] as? Int, 236, "indoor targets are a percentage of the prescription FTP")
        XCTAssertEqual(body["tags"] as? [String], ["threshold"])
        session.location = .outdoor
        t.responses = [HTTPResponse(status: 200, body: Data(#"{"id":9}"#.utf8))]
        _ = try await IntervalsClient(transport: t, credential: IntervalsCredential(accessToken: "k")).upsertPlannedWorkout(session, ftp: 250, existingEventID: 9)
        body = try XCTUnwrap(json(t.requests[1]) as? [String: Any])
        XCTAssertEqual(body["icu_ftp"] as? Int, 250, "outdoor watts were scaled to the outdoor FTP")
        XCTAssertEqual(body["indoor"] as? Bool, false)
    }

    func testIndoorToggleAndKindEditedInIntervalsAreAdoptedOnlyIfUnchangedHere() throws {
        var session = PlannedSession(day: monday, kind: .endurance, title: "E", targetMinutes: 60, intervalsEventID: 9, location: .indoor, prescriptionFTP: 240)
        session.mirrored = PlanMirror.nativeFields(for: session, ftp: 240)
        let edited = try events(#"[{"id":9,"external_id":"cadencia-ride-2026-11-02","indoor":false,"icu_ftp":255,"tags":["tempo","mine"]}]"#)[0]
        var adopted = session
        XCTAssertTrue(PlanMirror.adopt(edited, into: &adopted))
        XCTAssertEqual(adopted.location, .outdoor)
        XCTAssertEqual(adopted.kind, .tempo)
        XCTAssertEqual(adopted.prescriptionFTP, 240, "an outdoor event's icu_ftp is the outdoor FTP, not the prescription's")
        XCTAssertFalse(PlanMirror.adopt(edited, into: &adopted), "now in sync")

        var changedHere = session
        changedHere.location = .outdoor // not yet pushed
        XCTAssertFalse(PlanMirror.adopt(edited, into: &changedHere))
        XCTAssertEqual(changedHere.kind, .endurance)

        let ftpEdit = try events(#"[{"id":9,"indoor":true,"icu_ftp":231,"tags":["endurance"]}]"#)[0]
        var ftpAdopted = session
        XCTAssertTrue(PlanMirror.adopt(ftpEdit, into: &ftpAdopted))
        XCTAssertEqual(ftpAdopted.prescriptionFTP, 231)
    }

    func testCompletionComesFromThePairedActivityWithItsCompliance() {
        let session = PlannedSession(day: monday, kind: .endurance, title: "E", targetMinutes: 60, intervalsEventID: 9)
        let paired = ActivitySummary(id: "i1", name: "Ride", type: "Ride", startDateLocal: monday.date(), movingTime: 3600, pairedEventID: 9, compliance: 87)
        let other = ActivitySummary(id: "i2", name: "Ride", type: "Ride", startDateLocal: monday.date(), movingTime: 3600, pairedEventID: 10)
        XCTAssertEqual(PlanMirror.completion(for: session, activities: [other, paired]), .some(87))
        XCTAssertNil(PlanMirror.completion(for: session, activities: [other]), "nothing paired: not derived")
        XCTAssertNil(PlanMirror.completion(for: PlannedSession(day: monday, kind: .endurance, title: "E", targetMinutes: 60), activities: [paired]))
    }

    func testRetiredDaysExcludeDaysThatHaveARideAgainAndCalendarEntriesAreNotStaleRides() throws {
        let kept = PlannedSession(day: monday.adding(days: 1), kind: .endurance, title: "E", targetMinutes: 60)
        XCTAssertEqual(PlanMirror.retiredExternalIDs(days: [monday, monday.adding(days: 1), monday], keeping: [kept]), ["cadencia-ride-2026-11-02"])
        let calendar = try events("""
        [{"id":1,"external_id":"cadencia-other-gym-2026-11-03","category":"WORKOUT"},
         {"id":2,"external_id":"cadencia-race-2026-12-01","category":"RACE_A"},
         {"id":3,"external_id":"cadencia-ride-2026-11-02","category":"WORKOUT"},
         {"id":4,"uid":"cadencia-ride-2026-11-03","category":"WORKOUT"}]
        """)
        XCTAssertEqual(PlanMirror.staleEvents(calendar, sessions: [kept]).map(\.id), [3])
        XCTAssertEqual(PlanMirror.existingEvent(for: kept, in: calendar)?.id, 4)
    }

    func testLegacySessionUUIDEventsAreStillRecognised() throws {
        let session = PlannedSession(day: monday, kind: .endurance, title: "E", targetMinutes: 60)
        let legacy = try events("[{\"id\":5,\"external_id\":\"cadencia-\(session.id.uuidString.lowercased())\"}]")
        XCTAssertEqual(PlanMirror.existingEvent(for: session, in: legacy)?.id, 5, "updated in place, then carries the day id")
    }
}

// MARK: - 9. Units

final class UnitsSourceOfTruthTests: XCTestCase {
    func testMeasurementPreferenceMapsBothWaysAndUnknownValuesAreIgnored() {
        XCTAssertEqual(IntervalsAthleteFields.measurementPreference(metric: true), "meters")
        XCTAssertEqual(IntervalsAthleteFields.measurementPreference(metric: false), "feet")
        XCTAssertEqual(IntervalsAthleteFields.isMetric("meters"), true)
        XCTAssertEqual(IntervalsAthleteFields.isMetric("feet"), false)
        XCTAssertNil(IntervalsAthleteFields.isMetric("furlongs"))
        XCTAssertNil(IntervalsAthleteFields.isMetric(nil))
    }

    func testUnitsAreWrittenOnTheAthlete() async throws {
        let t = FakeTransport()
        let result = await IntervalsClient(transport: t, credential: IntervalsCredential(accessToken: "k"))
            .flush(IntervalsOutbox(measurementPreference: "feet"), ftp: nil, athlete: nil, today: monday)
        XCTAssertEqual(result.measurementPreference, "feet")
        XCTAssertEqual((try json(t.requests.first) as? [String: String])?["measurement_preference"], "feet")
    }
}

// MARK: - The one-time migration

final class MigrationTests: XCTestCase {
    func testMigrationUploadsLocalDataOnceWithoutOverwritingIntervals() {
        let feedback = [SubjectiveFeedback(day: monday, rpe: 6, legs: .heavy, motivation: 5),
                        SubjectiveFeedback(day: monday.adding(days: 1), legs: .fresh, note: "Great")]
        // Intervals already has Monday's soreness from the athlete; Cadencia must not overwrite it.
        let wellness = [WellnessDay(day: monday, soreness: 1)]
        let measurements = CyclistMeasurements(height: .init(value: 182, measuredAt: Date(), source: .athlete))
        let availability = [IntervalsAvailabilityDay(dayOfWeek: 1, level: .unavailable)]
        let athlete = AthleteProfile(id: "i1", name: "F", heightCm: 178, measurementPreference: "meters")
        let outbox = IntervalsMigration.outbox(feedback: feedback, wellness: wellness, measurements: measurements, athlete: athlete,
                                               unitsMetric: false, availability: availability,
                                               pendingWeight: WellnessUpdate(day: monday, weightKg: 71))
        XCTAssertEqual(outbox.wellness, [WellnessUpdate(day: monday, weightKg: 71, motivation: 1),
                                         WellnessUpdate(day: monday.adding(days: 1), soreness: 1, comments: "Great")])
        XCTAssertEqual(outbox.heightCm, 182)
        XCTAssertEqual(outbox.measurementPreference, "feet")
        XCTAssertEqual(outbox.availability, availability)
        let again = IntervalsMigration.outbox(feedback: feedback, wellness: wellness, measurements: measurements, athlete: athlete,
                                              unitsMetric: false, availability: availability,
                                              pendingWeight: WellnessUpdate(day: monday, weightKg: 71), existing: outbox)
        XCTAssertEqual(again, outbox, "idempotent")
        let metricDefault = IntervalsMigration.outbox(feedback: [], wellness: [], measurements: nil, athlete: athlete, unitsMetric: true,
                                                      availability: nil, pendingWeight: nil)
        XCTAssertTrue(metricDefault.isEmpty, "metric is a default, not a choice; Intervals' height wins when nothing local differs")
        let fromIntervals = IntervalsMigration.outbox(feedback: [], wellness: [], measurements: CyclistMeasurements(height: .init(value: 182, measuredAt: Date(), source: .intervals)),
                                                      athlete: nil, unitsMetric: true, availability: nil, pendingWeight: nil)
        XCTAssertNil(fromIntervals.heightCm)
    }
}

final class FeedbackChangeTests: XCTestCase {
    func testOnlyChangedFieldsAreSentAndClearedOnesAreUnset() {
        let old = SubjectiveFeedback(day: monday, rpe: 5, legs: .heavy, motivation: 4, note: "Sore")
        let new = SubjectiveFeedback(day: monday, rpe: 8, legs: nil, motivation: 4, note: nil, mood: 1)
        let update = WellnessUpdate(changingFrom: old, to: new)
        XCTAssertEqual(update, WellnessUpdate(day: monday, soreness: -1, mood: 1, comments: ""))
        let shown = SubjectiveFeedback(day: monday, legs: .heavy, note: "Sore").applying(update)
        XCTAssertNil(shown.legs)
        XCTAssertNil(shown.note)
        XCTAssertEqual(shown.mood, 1)
        XCTAssertTrue(WellnessUpdate(changingFrom: old, to: old).isEmpty, "an RPE-only change has nothing for wellness")
    }
}

final class RaceDayTests: XCTestCase {
    func testRaceDayIsOneEventCarryingTheSessionsMinutes() {
        let event = TrainingEvent(name: "Fondo", day: monday.adding(days: 5), isRace: false)
        var plan = TrainingPlan(goal: .event, title: "P", startDay: monday, endDay: monday.adding(days: 5), event: event,
                                availability: .typical, phases: [], sessions: [], isActive: true)
        let raceDay = PlannedSession(day: event.day, kind: .groupRide, title: "Fondo", targetMinutes: 240)
        let dayBefore = PlannedSession(day: event.day.adding(days: -1), kind: .openerActivation, title: "Opener", targetMinutes: 45)
        plan.sessions = [dayBefore, raceDay]
        XCTAssertTrue(CalendarEntry.raceDaySession(raceDay, in: plan), "the ride mirror leaves race day to the goal event")
        XCTAssertFalse(CalendarEntry.raceDaySession(dayBefore, in: plan))
        XCTAssertEqual(CalendarEntry.raceEntry(in: plan)?.movingTime, 14_400)
        XCTAssertEqual(CalendarEntry.entries(for: plan, today: monday).map(\.category), ["RACE_A"])
        XCTAssertTrue(CalendarEntry.entries(for: plan, today: monday.adding(days: 6)).isEmpty, "a past event is history")
    }
}
