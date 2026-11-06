import { describe, expect, it } from "@effect/vitest";
import { addDays } from "@cadencia/kernel/Day";
import { openerProblem, problemWith } from "../src/Plan/PrescriptionRules.ts";
import { endurance, evidence, longRide, steady, tuesday, workout } from "./fixtures.ts";

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
      "Include an easy warm-up before the first activation.",
    );
  });

  it("can't hide a long effort across two steps", () => {
    const split = workout("openerActivation", [
      steady("Warm-up", 30, 0.6),
      steady("Effort", 2, 1.0),
      steady("Effort", 2, 1.0),
      steady("Easy", 30, 0.55),
    ]);
    expect(openerProblem(split)).toBe("An opener activation is too long. Use brief efforts, not sustained training intervals.");
  });

  it("are allowed the day before a confirmed event", () => {
    const tuesdayOpener = { ...longRide, day: tuesday, kind: "openerActivation" as const, targetMinutes: 60 };
    const withEvent = { ...evidence(), eventDays: [addDays(tuesday, 1)] };
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
    ).toEqual({ _tag: "PurposeMismatch", reason: "A rest day must have no riding blocks." });
  });
});
