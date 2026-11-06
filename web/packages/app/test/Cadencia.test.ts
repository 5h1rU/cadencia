import { AthleteId } from "@cadencia/identity/Athlete.id";
import { Day } from "@cadencia/kernel/Calendar/Day";
import { describe, expect, it } from "@effect/vitest";
import * as Option from "effect/Option";
import { declarationOf, init, Message, update } from "../src/Cadencia.ts";

const signedIn = init({ athleteId: AthleteId.make("i100"), today: Day.make("2026-11-09"), session: "s" }).model;
const signedOut = init({ athleteId: null, today: Day.make("2026-11-09"), session: "s" }).model;

describe("the web app", () => {
  it("reads Intervals when the athlete opens the history", () => {
    const next = update(signedIn, Message.ClickedSection({ section: "history" }));
    expect(next.model.section).toBe("history");
    expect(next.commands?.length).toBe(1);
  });

  it("doesn't call Intervals for a signed-out visitor", () => {
    const next = update(signedOut, Message.ClickedSection({ section: "profile" }));
    expect(next.commands ?? []).toEqual([]);
  });

  it("explains what's missing instead of sending an incomplete move", () => {
    const next = update(signedIn, Message.SubmittedMove());
    expect(Option.getOrNull(next.model.error)).toBe("Elige una sesión y un día nuevo.");
    expect(next.commands ?? []).toEqual([]);
  });

  it("asks before retiring the plan", () => {
    const asked = update(signedIn, Message.ClickedRetire());
    expect(asked.model.confirmRetire).toBe(true);
    expect(update(asked.model, Message.ClickedCancelRetire()).model.confirmRetire).toBe(false);
  });

  it("names a refusal in the athlete's words", () => {
    const next = update(signedIn, Message.FailedWrite({ action: "moveSession", reason: "DayTaken" }));
    expect(Option.getOrNull(next.model.error)).toBe("Ese día ya tiene otra sesión.");
  });
});

describe("the wellness form", () => {
  const form = { mood: "", motivation: "", soreness: "", fatigue: "", weight: "", comments: "" };

  it("sends only what the athlete filled in, in Intervals' units", () => {
    expect(Option.getOrNull(declarationOf({ ...form, mood: "3", weight: "74.1", comments: " Legs heavy " }))).toEqual({
      mood: 3,
      weight: 74.1,
      comments: "Legs heavy",
    });
  });

  it("refuses values outside Intervals' scales", () => {
    expect(Option.isNone(declarationOf({ ...form, mood: "5" }))).toBe(true);
    expect(Option.isNone(declarationOf({ ...form, weight: "7" }))).toBe(true);
    expect(Option.isNone(declarationOf({ ...form, fatigue: "two" }))).toBe(true);
  });
});
