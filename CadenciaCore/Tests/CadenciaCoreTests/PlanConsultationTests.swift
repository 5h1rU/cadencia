import XCTest
@testable import CadenciaCore

final class PlanConsultationTests: XCTestCase {
    let today = Day(year: 2026, month: 11, day: 4)

    private func draft() -> PlanConsultation.Draft {
        .init(title: "Stronger on long rides", goal: .durability, startDay: today, endDay: today.adding(days: 27),
              details: .init(objective: "Finish long rides stronger", rationale: "Build around CrossFit and the trip",
                             weeklyRides: [.init(weekday: 5, minutes: 60, kind: .threshold), .init(weekday: 1, minutes: 120, kind: .longRide)],
                             otherTraining: [.init(name: "CrossFit", weekdays: [4], minutes: 45, intensity: .hard)],
                             timeAway: [.init(start: today.adding(days: 14), end: today.adding(days: 20), reason: "Vacation")]),
              phases: [.init(focus: .base, startWeek: 1, endWeek: 3, summary: "Build a routine"),
                       .init(focus: .recover, startWeek: 4, endWeek: 4, summary: "Absorb the work")])
    }

    func testDraftKeepsVacationOffAndSoftensRideAfterHardCrossFit() throws {
        let draft = draft()
        let plan = try draft.makePlan(today: today)
        XCTAssertFalse(plan.isActive, "A validated draft still needs explicit acceptance")
        XCTAssertEqual(plan.consultation?.otherTraining.first?.name, "CrossFit")
        XCTAssertTrue(plan.sessions.allSatisfy { !draft.details.isUnavailable($0.day) })
        XCTAssertEqual(plan.sessions.first?.kind, .endurance)
        XCTAssertEqual(plan.sessions.first?.targetMinutes, 60)
        XCTAssertEqual(plan.sessions.last?.kind, .recovery)
        XCTAssertTrue(plan.sessions.allSatisfy { $0.workout == nil })
    }

    func testDraftRequiresConfirmedIntakeButDoesNotRequireMeasurements() throws {
        var reply = PlanConsultation.Reply(review: "We have the goal and schedule.", question: "Review?", topic: .review,
                                           coveredTopics: [.goal, .availability, .timeAway], draft: draft())
        XCTAssertThrowsError(try reply.validate(today: today))
        reply.coveredTopics.append(.otherTraining)
        XCTAssertNoThrow(try reply.validate(today: today))
        XCTAssertNil(CyclistMeasurements.wattsPerKg(ftp: nil, weightKg: 75))
        XCTAssertNil(CyclistMeasurements.wattsPerKg(ftp: 240, weightKg: nil))
        XCTAssertEqual(CyclistMeasurements.wattsPerKg(ftp: 240, weightKg: 75), 3.2)
    }

    func testRejectsCalendarRolloverAndInvalidAvailability() throws {
        var bad = draft()
        bad.startDay = Day(year: 2026, month: 11, day: 31)
        XCTAssertThrowsError(try bad.makePlan(today: today))
        bad = draft()
        bad.details.weeklyRides.append(bad.details.weeklyRides[0])
        XCTAssertThrowsError(try bad.makePlan(today: today))
    }

    func testOlderHealthSampleCannotReplaceConfirmedProfileValue() throws {
        let confirmed = CyclistMeasurements.Measurement(value: 75, measuredAt: today.date(), source: .athlete)
        var body = CyclistMeasurements(weight: confirmed)
        body.merge(.init(weight: .init(value: 70, measuredAt: today.adding(days: -1).date(), source: .appleHealth),
                         height: .init(value: 178, measuredAt: today.date(), source: .appleHealth)))
        XCTAssertEqual(body.weight, confirmed)
        XCTAssertEqual(body.height?.value, 178)
        XCTAssertThrowsError(try PlanConsultation.ProfileUpdate(weightKg: 0).validate())
    }
}
