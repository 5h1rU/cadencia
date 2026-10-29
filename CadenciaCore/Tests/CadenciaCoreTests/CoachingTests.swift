import XCTest
@testable import CadenciaCore

final class ReadinessEngineTests: XCTestCase {
    let engine = ReadinessEngine()
    let today = Day(year: 2026, month: 10, day: 28)

    func history(hrv: Double = 65, sleep: Int = 7 * 3600 + 30 * 60, rhr: Int = 50, days: Int = 28) -> [WellnessDay] {
        (1...days).map { i in
            // Small deterministic wobble so the SD is not zero.
            let wobble = Double(i % 5) - 2
            return WellnessDay(day: today.adding(days: -i), hrvMs: hrv + wobble * 2, restingHR: rhr + Int(wobble), sleepSeconds: sleep + Int(wobble) * 600, ctl: 60, atl: 60)
        }
    }

    func testLowHRVShortSleepAndDeepFatigueCallsForEasyDay() {
        let today = WellnessDay(day: today, hrvMs: 48, restingHR: 54, sleepSeconds: 6 * 3600 + 12 * 60, ctl: 62, atl: 78)
        let r = engine.evaluate(today: today, history: history())
        XCTAssertEqual(r.level, .easy, "score \(r.score) signals \(r.signals)")
        XCTAssertEqual(r.signals.first { $0.name == "hrv" }?.verdict, .below)
        XCTAssertEqual(r.signals.first { $0.name == "sleep" }?.verdict, .below)
        XCTAssertTrue(r.missingData.isEmpty)
    }

    func testTypicalDayIsNormal() {
        let today = WellnessDay(day: today, hrvMs: 66, restingHR: 50, sleepSeconds: 7 * 3600 + 20 * 60, ctl: 60, atl: 62)
        let r = engine.evaluate(today: today, history: history())
        XCTAssertEqual(r.level, .normal, "score \(r.score)")
    }

    func testHighHRVPositiveFormIsStrong() {
        let today = WellnessDay(day: today, hrvMs: 78, restingHR: 47, sleepSeconds: 8 * 3600, ctl: 60, atl: 50)
        let r = engine.evaluate(today: today, history: history())
        XCTAssertEqual(r.level, .strong, "score \(r.score)")
    }

    func testHeavyLegsDowngradesAnOtherwiseNormalDay() {
        let today = WellnessDay(day: today, hrvMs: 66, restingHR: 50, sleepSeconds: 7 * 3600 + 20 * 60, ctl: 60, atl: 70)
        let normal = engine.evaluate(today: today, history: history())
        let heavy = engine.evaluate(today: today, history: history(), feedback: SubjectiveFeedback(day: self.today, legs: .heavy))
        XCTAssertLessThan(heavy.score, normal.score)
        XCTAssertEqual(heavy.level, .easy, "score \(heavy.score)")
    }

    func testFewerThanSevenBaselineDaysMeansSignalsAreMissingAndNeverStrong() {
        let today = WellnessDay(day: today, hrvMs: 90, restingHR: 45, sleepSeconds: 9 * 3600, ctl: 60, atl: 40)
        let r = engine.evaluate(today: today, history: history(days: 4))
        XCTAssertEqual(Set(r.missingData), ["hrv", "sleep", "restingHR"])
        XCTAssertNotEqual(r.level, .strong)
        XCTAssertFalse(r.isSufficientlyInformed == false && r.signals.filter { $0.verdict != .missing }.count >= 2)
    }

    func testBaselineIgnoresTodayAndFutureDays() {
        // A wildly different "future" day must not shift the baseline.
        var hist = history()
        hist.append(WellnessDay(day: today.adding(days: 1), hrvMs: 500, restingHR: 20, sleepSeconds: 20 * 3600))
        let today = WellnessDay(day: today, hrvMs: 66, restingHR: 50, sleepSeconds: 7 * 3600 + 20 * 60, ctl: 60, atl: 62)
        let r = engine.evaluate(today: today, history: hist)
        XCTAssertEqual(r.signals.first { $0.name == "hrv" }?.verdict, .typical)
    }
}

final class DailyPrescriberTests: XCTestCase {
    let p = DailyPrescriber()
    let day = Day(year: 2026, month: 10, day: 28)

    func readiness(_ level: Readiness.Level) -> Readiness {
        Readiness(level: level, score: 50, signals: [], missingData: [], summary: "")
    }

    func testEasyReadinessTurnsThresholdIntoCappedEndurance() {
        let planned = PlannedSession(day: day, kind: .threshold, title: "Threshold", targetMinutes: 90)
        let w = p.prescribe(.init(day: day, planned: planned, readiness: readiness(.easy), ftp: 240))
        XCTAssertEqual(w.kind, .endurance)
        XCTAssertEqual(w.totalDuration, 75 * 60)
        XCTAssertEqual(w.intensityCeiling, 0.69)
        XCTAssertEqual(w.targetWatts(ftp: 240, at: 20 * 60), 156) // 0.65 × 240
        XCTAssertLessThanOrEqual(w.steps.map(\.endIntensity).max()!, 0.69)
    }

    func testStrongReadinessKeepsThresholdAsPlanned() {
        let planned = PlannedSession(day: day, kind: .threshold, title: "Threshold", targetMinutes: 75)
        let w = p.prescribe(.init(day: day, planned: planned, readiness: readiness(.strong), ftp: 240))
        XCTAssertEqual(w.kind, .threshold)
        XCTAssertEqual(w.totalDuration, 75 * 60, accuracy: 1)
        XCTAssertTrue(w.steps.contains { $0.name.hasPrefix("Threshold") && $0.startIntensity == 0.98 })
    }

    func testRestReadinessProducesNoSteps() {
        let planned = PlannedSession(day: day, kind: .endurance, title: "Endurance", targetMinutes: 60)
        let w = p.prescribe(.init(day: day, planned: planned, readiness: readiness(.rest), ftp: 240))
        XCTAssertEqual(w.kind, .rest)
        XCTAssertTrue(w.steps.isEmpty)
    }

    func testDayBeforeAPriorityEventIsAnOpenerEvenWhenStrong() {
        let event = TrainingEvent(name: "Gran fondo", day: day.adding(days: 1), distanceKm: 200)
        let planned = PlannedSession(day: day, kind: .vo2max, title: "VO2", targetMinutes: 75)
        let w = p.prescribe(.init(day: day, planned: planned, readiness: readiness(.strong), ftp: 240, upcomingPriorityEvent: event))
        XCTAssertEqual(w.kind, .openerActivation)
        XCTAssertLessThanOrEqual(w.totalDuration, 30 * 60)
    }

    func testAvailableMinutesCapTheSession() {
        let planned = PlannedSession(day: day, kind: .endurance, title: "Endurance", targetMinutes: 90)
        let w = p.prescribe(.init(day: day, planned: planned, readiness: readiness(.normal), ftp: 240, availableMinutes: 40))
        XCTAssertEqual(w.totalDuration, 40 * 60)
    }

    func testCeilingClampsTargetWattsInsideRamp() {
        let w = Workout(name: "x", kind: .endurance, steps: [WorkoutStep(name: "ramp", duration: 100, startIntensity: 0.5, endIntensity: 1.0)], intensityCeiling: 0.7)
        XCTAssertEqual(w.targetWatts(ftp: 200, at: 0), 100)
        XCTAssertEqual(w.targetWatts(ftp: 200, at: 50), 140)   // 0.75 clamped to 0.7
        XCTAssertNil(w.targetWatts(ftp: 200, at: 100))
    }
}

final class FTPEstimatorTests: XCTestCase {
    let e = FTPEstimator()

    func testUsesStrongestOfTheThreeModelsAndReportsBasis() {
        // P20 = 260 → 247. P60 = 250. CP from P3 = 340, P12 = 270 → (270·720 − 340·180)/540 = 246.7
        let curve = [PowerCurvePoint(seconds: 180, watts: 340), .init(seconds: 720, watts: 270), .init(seconds: 1200, watts: 260), .init(seconds: 3600, watts: 250)]
        let est = e.estimate(curve: curve, sustainedEfforts: 3)!
        XCTAssertEqual(est.watts, 250)
        XCTAssertEqual(est.basis, "best 60 min")
        XCTAssertEqual(est.confidence, .moderate)
    }

    func testNoUsableDurationsMeansNoEstimate() {
        XCTAssertNil(e.estimate(curve: [PowerCurvePoint(seconds: 5, watts: 900)], sustainedEfforts: 0))
    }

    func testProposalIgnoresTinyIncreasesAndLowConfidence() {
        XCTAssertNil(e.proposal(current: 240, estimate: FTPEstimate(watts: 243, confidence: .high, sustainedEfforts: 5, basis: "", windowDays: 42)))
        XCTAssertEqual(e.proposal(current: 240, estimate: FTPEstimate(watts: 248, confidence: .moderate, sustainedEfforts: 3, basis: "", windowDays: 42)), 248)
        XCTAssertNil(e.proposal(current: 240, estimate: FTPEstimate(watts: 260, confidence: .low, sustainedEfforts: 1, basis: "", windowDays: 42)))
        XCTAssertNil(e.proposal(current: 240, estimate: FTPEstimate(watts: 232, confidence: .high, sustainedEfforts: 5, basis: "", windowDays: 42)), "−3 % is inside the hysteresis")
        XCTAssertEqual(e.proposal(current: 240, estimate: FTPEstimate(watts: 226, confidence: .high, sustainedEfforts: 5, basis: "", windowDays: 42)), 226)
    }
}

final class PlanBuilderTests: XCTestCase {
    // 2026-11-02 is a Monday; 2027-02-21 is a Sunday.
    let start = Day(year: 2026, month: 11, day: 2)
    let eventDay = Day(year: 2027, month: 2, day: 21)

    func testEventPlanHasSixteenWeeksPhasesAndTheEventOnItsDay() {
        let event = TrainingEvent(name: "Gran fondo", day: eventDay, distanceKm: 200, priority: .a, objective: "finish strong", isRace: true)
        let plan = PlanBuilder().build(.init(goal: .event, startDay: start, endDay: eventDay, event: event, availability: .typical))
        XCTAssertEqual(plan.weekCount, 16)
        XCTAssertEqual(plan.phases.map(\.focus), [.base, .build, .peak, .taper])
        XCTAssertEqual(plan.phases.last?.startWeek, 16)
        let race = plan.sessions.first { $0.day == eventDay }
        XCTAssertEqual(race?.kind, .race)
        XCTAssertTrue(race?.isPriority == true)
        var groupRide = event
        groupRide.isRace = false
        let plan2 = PlanBuilder().build(.init(goal: .event, startDay: start, endDay: eventDay, event: groupRide, availability: .typical))
        XCTAssertEqual(plan2.sessions.first { $0.day == eventDay }?.kind, .groupRide, "priority is independent of race vs group ride")
        XCTAssertTrue(plan2.sessions.first { $0.day == eventDay }?.isPriority == true)
        XCTAssertEqual(plan.sessions.first { $0.day == eventDay.adding(days: -1) }?.kind, .openerActivation)
        XCTAssertEqual(plan.weekNumber(of: Day(year: 2026, month: 11, day: 4)), 1)
        XCTAssertEqual(plan.phase(for: eventDay)?.focus, .taper)
    }

    func testOnlyAvailableDaysGetSessionsAndLongRideLandsOnItsWeekday() {
        let plan = PlanBuilder().build(.init(goal: .climbing, startDay: start, endDay: start.adding(days: 55), availability: .typical))
        XCTAssertEqual(plan.weekCount, 8)
        XCTAssertTrue(plan.sessions.allSatisfy { Availability.typical.minutesByWeekday[$0.day.weekday()] != nil })
        XCTAssertFalse(plan.sessions.contains { $0.day.weekday() == 6 }, "Friday is not available in .typical")
        let sundays = plan.sessions.filter { $0.day.weekday() == 1 }
        XCTAssertEqual(sundays.count, 8)
        XCTAssertTrue(sundays.allSatisfy { $0.kind == .longRide })
        XCTAssertTrue(plan.sessions.allSatisfy { $0.status == .provisional }, "future sessions are intentions, not generated workouts")
    }

    func testRecoveryWeekHasNoHardSessions() {
        let plan = PlanBuilder().build(.init(goal: .ftp, startDay: start, endDay: start.adding(days: 55), availability: .typical))
        let week4 = plan.sessions.filter { plan.weekNumber(of: $0.day) == 4 }
        XCTAssertFalse(week4.isEmpty)
        XCTAssertFalse(week4.contains { $0.kind.isHard })
        let week3 = plan.sessions.filter { plan.weekNumber(of: $0.day) == 3 }
        XCTAssertTrue(week3.contains { $0.kind.isHard })
    }
}

final class WeekReviserTests: XCTestCase {
    let monday = Day(year: 2026, month: 10, day: 26)

    func makePlan() -> TrainingPlan {
        PlanBuilder().build(.init(goal: .endurance, startDay: monday, endDay: monday.adding(days: 27), availability: .typical))
    }

    func testEventOnSundayPinsPriorityAndSoftensTheTwoDaysBefore() {
        let today = monday.adding(days: 2) // Wednesday
        let sunday = monday.adding(days: 6)
        let intent = CoachIntent(event: TrainingEvent(name: "Group ride 200 km", day: sunday, distanceKm: 200, priority: .a, objective: "arrive fresh"),
                                 constraints: [.init(day: monday.adding(days: 3), maxMinutes: 40)])
        let rev = WeekReviser().apply(intent, to: makePlan(), today: today)
        let week = rev.plan.sessions(inWeekOf: today)
        XCTAssertEqual(week.first { $0.day == sunday }?.kind, .groupRide)
        XCTAssertEqual(week.first { $0.day == sunday }?.isPriority, true)
        XCTAssertEqual(week.first { $0.day == sunday.adding(days: -1) }?.kind, .openerActivation)
        XCTAssertEqual(week.first { $0.day == monday.adding(days: 3) }?.targetMinutes, 40)
        XCTAssertTrue(rev.changed.contains { $0.day == sunday })
        // Thursday is 40 min and was a hard day in .typical availability? Either way it must not exceed the cap.
        XCTAssertTrue(week.filter { $0.day == monday.adding(days: 3) }.allSatisfy { $0.targetMinutes <= 40 })
    }

    func testConstraintsInThePastAreIgnored() {
        let today = monday.adding(days: 3)
        let intent = CoachIntent(constraints: [.init(day: monday.adding(days: 1), unavailable: true)])
        let rev = WeekReviser().apply(intent, to: makePlan(), today: today)
        XCTAssertTrue(rev.changed.isEmpty)
        XCTAssertEqual(rev.plan.sessions.first { $0.day == monday.adding(days: 1) }?.status, .provisional)
    }
}

final class HeuristicCoachTests: XCTestCase {
    let wednesday = Day(year: 2026, month: 10, day: 28)

    func testSpanishVoiceNoteFromTheDesign() {
        let intent = HeuristicCoach.parse("El domingo tengo una salida de 200 km. Quiero llegar fresco y mañana solo tengo 40 minutos.", today: wednesday)
        XCTAssertEqual(intent.event?.day, Day(year: 2026, month: 11, day: 1))
        XCTAssertEqual(intent.event?.distanceKm, 200)
        XCTAssertEqual(intent.event?.objective, "arrive fresh")
        XCTAssertEqual(intent.constraints, [.init(day: Day(year: 2026, month: 10, day: 29), maxMinutes: 40)])
        XCTAssertTrue(intent.needsClarification.isEmpty)
    }

    func testEnglishWithHoursAndDayOff() {
        let intent = HeuristicCoach.parse("Saturday I can't train. Tuesday I only have 1 hour. Legs feel heavy today.", today: wednesday)
        XCTAssertEqual(intent.constraints.count, 2)
        XCTAssertEqual(intent.constraints.first { $0.unavailable }?.day, Day(year: 2026, month: 10, day: 31))
        XCTAssertEqual(intent.constraints.first { !$0.unavailable }?.maxMinutes, 60)
        XCTAssertEqual(intent.constraints.first { !$0.unavailable }?.day, Day(year: 2026, month: 11, day: 3), "next Tuesday, not last")
        XCTAssertEqual(intent.feeling, .heavy)
        XCTAssertNil(intent.event)
    }

    func testNothingUnderstoodAsksForClarification() {
        let intent = HeuristicCoach.parse("hola qué tal", today: wednesday)
        XCTAssertTrue(intent.isEmpty)
        XCTAssertFalse(intent.needsClarification.isEmpty)
    }

    func testLLMWireMapping() {
        let wire = LLMCoach.Wire(event: .init(name: "Race", day: "2026-11-01", distanceKm: 120, priority: "b", objective: "finish strong"),
                                 constraints: [.init(day: "2026-10-30", maxMinutes: nil, unavailable: true), .init(day: "bad", maxMinutes: 30, unavailable: nil)],
                                 feeling: "fresh", goal: "climbing", reply: "ok", needsClarification: nil)
        let intent = LLMCoach.intent(from: wire)
        XCTAssertEqual(intent.event?.priority, .b)
        XCTAssertEqual(intent.constraints.count, 1, "invalid dates are dropped, never guessed")
        XCTAssertEqual(intent.feeling, .fresh)
        XCTAssertEqual(intent.goal, .climbing)
    }
}
