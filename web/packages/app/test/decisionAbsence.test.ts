import { describe, expect, it } from "@effect/vitest";
import { Day } from "@cadencia/kernel/Calendar/Day";
import * as Option from "effect/Option";
import * as Scene from "foldkit/scene";
import { DECISION_ABSENCES, decisionAbsence } from "../src/domain/decisionAbsence.ts";
import { Message } from "../src/message.ts";
import { update } from "../src/update.ts";
import { view } from "../src/view.ts";
import { plan, signedIn, today } from "./fixture.ts";

describe("a day without a decision on the web", () => {
  it("stays on the iPhone without an active plan covering it", () => {
    expect(decisionAbsence(Option.none(), today)).toBe("noPlan");
    expect(decisionAbsence(Option.some({ ...plan, status: "retired" }), Day.make("2026-11-10"))).toBe("noPlan");
    expect(decisionAbsence(Option.some(plan), Day.make("2026-11-01"))).toBe("noPlan");
    expect(decisionAbsence(Option.some(plan), Day.make("2026-12-28"))).toBe("noPlan");
  });

  it("may stay on the iPhone on a day the plan leaves free, skipped sessions included", () => {
    expect(decisionAbsence(Option.some(plan), today)).toBe("freeDay");
    expect(decisionAbsence(Option.some(plan), Day.make("2026-11-12"))).toBe("freeDay");
  });

  it("is still to come on a day the plan has a session", () => {
    expect(decisionAbsence(Option.some(plan), Day.make("2026-11-10"))).toBe("notYet");
    expect(decisionAbsence(Option.some(plan), Day.make("2026-11-11"))).toBe("notYet");
  });

  it("says why on Home", () => {
    const withoutDecision = update(signedIn, Message.ReceivedDecision({ decision: Option.none() })).model;
    const shows = (planRead: Option.Option<typeof plan>, text: string) =>
      Scene.scene(
        { update, view },
        Scene.given(update(withoutDecision, Message.ReceivedPlan({ plan: planRead })).model),
        Scene.expect(Scene.text(text)).toExist(),
      );
    shows(Option.none(), DECISION_ABSENCES.noPlan);
    shows(Option.some(plan), DECISION_ABSENCES.freeDay);
    // Before the plan is read, Home says what holds whatever it says.
    Scene.scene(
      { update, view },
      Scene.given(withoutDecision),
      Scene.expect(Scene.text(DECISION_ABSENCES.notYet)).toExist(),
    );
  });
});
