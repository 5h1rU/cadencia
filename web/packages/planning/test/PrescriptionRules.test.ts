import { describe, expect, it } from "@effect/vitest";
import { openerProblem, problemWith } from "../src/Plan/PrescriptionRules.ts";
import type { Workout } from "@cadencia/kernel/Training/Workout";
import type { PlannedSession } from "../src/Plan/PlannedSession.ts";
import {
  easyHour,
  endurance,
  evidence,
  intensity,
  intervals,
  longRide,
  minutes,
  steady,
  threshold,
  tuesday,
  workout,
} from "./fixtures.ts";

const opener = workout("openerActivation", [
  steady("Warm-up", 20, 0.6),
  steady("Effort", 1, 1.05),
  steady("Easy", 3, 0.55),
  steady("Effort", 1, 1.05),
  steady("Cool-down", 10, 0.55),
]);

describe("openers", () => {
  it("accept brief efforts inside mostly easy riding", () => {
    expect(openerProblem(opener)).toBeUndefined();
  });

  it("need a warm-up before the first effort", () => {
    expect(openerProblem(workout("openerActivation", [steady("Effort", 1, 1.05), steady("Easy", 30, 0.55)]))).toBe(
      "openerWithoutWarmUp",
    );
  });

  it("can't hide a long effort across two steps", () => {
    const split = workout("openerActivation", [
      steady("Warm-up", 30, 0.6),
      steady("Effort", 2, 1.0),
      steady("Effort", 2, 1.0),
      steady("Easy", 30, 0.55),
    ]);
    expect(openerProblem(split)).toBe("openerEffortTooLong");
  });

  it("are allowed the day before a confirmed event", () => {
    const tuesdayOpener = { ...longRide, day: tuesday, kind: "openerActivation" as const, targetMinutes: minutes(60) };
    const withEvent = evidence([], ["2026-11-11"]);
    expect(problemWith({ session: tuesdayOpener, workout: opener, evidence: withEvent, requirement: undefined, goalEvent: null })).toBeUndefined();
  });
});

describe("rest days", () => {
  it("have no riding blocks", () => {
    expect(
      problemWith({
        session: endurance,
        workout: workout("rest", [steady("Spin", 20, 0.5)]),
        evidence: evidence(),
        requirement: undefined,
        goalEvent: null,
      }),
    ).toEqual({ _tag: "PurposeMismatch", problem: "restWithRiding" });
  });
});

describe("a proposal never asks more than the planned session's purpose", () => {
  const check = (session: PlannedSession, proposal: Workout) =>
    problemWith({ session, workout: proposal, evidence: evidence(), requirement: undefined, goalEvent: null })?._tag;
  const tempo = { ...threshold, kind: "tempo" as const };
  const vo2 = { ...threshold, kind: "vo2max" as const };
  const sweetSpot = workout("tempo", [steady("Warm-up", 15, 0.6), steady("Sweet spot", 40, 0.9), steady("Cool-down", 10, 0.55)]);
  const vo2Intervals = workout("vo2max", [steady("Warm-up", 20, 0.6), steady("VO2", 20, 1.3), steady("Cool-down", 20, 0.55)]);
  const race = workout("race", [steady("Race", 60, 1.1)]);
  const spiky = workout("threshold", [steady("Warm-up", 15, 0.6), steady("Surges", 20, 1.2), steady("Cool-down", 15, 0.55)]);

  it("lets a hard day become easier or stay as planned", () => {
    expect(check(threshold, intervals)).toBeUndefined();
    expect(check(threshold, sweetSpot)).toBeUndefined();
    expect(check(threshold, easyHour)).toBeUndefined();
    expect(check(vo2, vo2Intervals)).toBeUndefined();
  });

  it("refuses a harder kind, even when it is shorter", () => {
    expect(check(threshold, vo2Intervals)).toBe("HardensPlannedSession");
    expect(check(tempo, race)).toBe("HardensPlannedSession");
    expect(check(tempo, intervals)).toBe("HardensPlannedSession");
  });

  it("refuses efforts above the planned kind's ceiling", () => {
    expect(check(threshold, spiky)).toBe("HardensPlannedSession");
  });

  it("keeps an opener day to an opener", () => {
    const openerDay = { ...threshold, kind: "openerActivation" as const };
    expect(check(openerDay, intervals)).toBe("HardensPlannedSession");
    expect(check(openerDay, easyHour)).toBeUndefined();
  });

  it("refuses a session that never eases off, even under the kind's peak", () => {
    // Under threshold's peak of 110 %, but the whole session at it; under tempo's of 100 %, likewise.
    expect(check(threshold, workout("threshold", [steady("All of it", 75, 1.1)]))).toBe("HardensPlannedSession");
    expect(check(tempo, workout("endurance", [steady("All of it", 75, 1.0)]))).toBe("HardensPlannedSession");
    // The same efforts with their warm-up and recoveries are the kind's own dose.
    const twoByTwenty = workout("threshold", [
      steady("Warm-up", 15, 0.6),
      steady("Threshold", 20, 1.0),
      steady("Easy", 5, 0.55),
      steady("Threshold", 20, 1.0),
      steady("Cool-down", 15, 0.55),
    ]);
    expect(check(threshold, twoByTwenty)).toBeUndefined();
    expect(check(tempo, workout("tempo", [steady("Warm-up", 10, 0.6), steady("Tempo", 55, 0.85), steady("Cool-down", 10, 0.55)]))).toBeUndefined();
  });

  it("keeps the bike easy on a strength day, and leaves a group ride to the athlete", () => {
    const gym = { ...threshold, kind: "strength" as const };
    const groupRide = { ...threshold, kind: "groupRide" as const };
    expect(check(gym, vo2Intervals)).toBe("HardensPlannedSession");
    expect(check(gym, easyHour)).toBeUndefined();
    expect(check(gym, workout("strength", []))).toBeUndefined();
    expect(check(groupRide, vo2Intervals)).toBeUndefined();
  });

  /** One ordinary workout of each kind that has a place on the ladder, easiest first. */
  const ladder: ReadonlyArray<readonly [PlannedSession["kind"], Workout]> = [
    ["recovery", workout("recovery", [steady("Spin", 40, 0.5)])],
    ["endurance", easyHour],
    ["tempo", sweetSpot],
    ["threshold", intervals],
    ["vo2max", vo2Intervals],
    ["race", workout("race", [steady("Warm-up", 15, 0.6), steady("Race", 40, 1.05)])],
  ];

  it("accepts every kind on its own day or a harder one, and refuses it on an easier one", () => {
    for (const [plannedAt, [planned]] of ladder.entries()) {
      for (const [proposedAt, [proposed, proposal]] of ladder.entries()) {
        // Recovery, endurance and the long ride are all easy days: none adds intensity to another.
        const harder = proposedAt > plannedAt && proposedAt > 1;
        expect(check({ ...threshold, kind: planned }, proposal), `${proposed} on a ${planned} day`).toBe(
          harder ? "HardensPlannedSession" : undefined,
        );
      }
    }
  });
});

describe("an effort nobody could finish", () => {
  const check = (session: PlannedSession, proposal: Workout) =>
    problemWith({ session, workout: proposal, evidence: evidence(), requirement: undefined, goalEvent: null });
  const vo2 = { ...threshold, kind: "vo2max" as const };
  const beyondReach = { _tag: "PurposeMismatch", problem: "effortBeyondReach" };

  it("is refused on any day, whatever the kind", () => {
    const hourAtDouble = workout("vo2max", [steady("Warm-up", 10, 0.6), steady("Effort", 60, 2.0)]);
    expect(check(vo2, hourAtDouble)).toEqual(beyondReach);
    expect(check({ ...threshold, kind: "race" }, workout("race", [steady("Race", 70, 1.2)]))).toEqual(beyondReach);
    expect(check({ ...threshold, kind: "groupRide" }, hourAtDouble)).toEqual(beyondReach);
  });

  it("is one unbroken effort: recoveries between hard efforts start it again", () => {
    const fiveByFive = workout("vo2max", [
      steady("Warm-up", 15, 0.6),
      ...[1, 2, 3, 4, 5].flatMap((n) => [steady(`VO2 ${n}`, 5, 1.2), steady("Easy", 5, 0.5)]),
    ]);
    expect(check(vo2, fiveByFive)).toBeUndefined();
    // A sprint far above FTP is brief enough to be within reach.
    expect(check(vo2, workout("vo2max", [steady("Warm-up", 20, 0.6), steady("Sprint", 0.5, 3), steady("Easy", 10, 0.5)]))).toBeUndefined();
  });

  it("counts only the part of a ramp that is above FTP", () => {
    const ramp = (to: number) =>
      workout("vo2max", [{ ...steady("Ramp", 40, 0.5), endIntensity: intensity(to) }, steady("Cool-down", 10, 0.5)]);
    expect(check(vo2, ramp(1.3))).toBeUndefined();
    expect(check(vo2, ramp(3))).toEqual(beyondReach);
  });
});
