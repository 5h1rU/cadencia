import { describe, expect, it } from "@effect/vitest";
import { openerProblem, problemWith } from "../src/Plan/PrescriptionRules.ts";
import type { Workout } from "@cadencia/kernel/Training/Workout";
import type { PlannedSession } from "../src/Plan/PlannedSession.ts";
import { easyHour, endurance, evidence, intervals, longRide, minutes, steady, threshold, tuesday, workout } from "./fixtures.ts";

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
});
