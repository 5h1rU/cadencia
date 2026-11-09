import { conversationIdFor, YearMonth } from "@cadencia/coach/Conversation/Conversation.id";
import { IntentExpired } from "@cadencia/coach/Conversation/AcceptIntent.command";
import { MessageId } from "@cadencia/coach/Conversation/Message.id";
import { Unauthorized } from "@cadencia/identity/Session.middleware";
import { Day } from "@cadencia/kernel/Calendar/Day";
import { Paragraph } from "@cadencia/kernel/Text";
import { ImplausibleToday } from "@cadencia/planning/Plan/ImplausibleToday.rejection";
import { DayTaken, SessionNotMovable } from "@cadencia/planning/Plan/MoveSession.command";
import { SessionId } from "@cadencia/planning/Plan/Session.id";
import { describe, expect, it } from "@effect/vitest";
import * as Option from "effect/Option";
import { AsyncData, FieldValidation } from "foldkit";
import * as Scene from "foldkit/scene";
import * as Story from "foldkit/story";
import { CoachClient, PlanningClient } from "../src/client.ts";
import { commandFor } from "../src/command.ts";
import { Message } from "../src/message.ts";
import { LivePlan, Model, Write } from "../src/model.ts";
import { isMovable } from "../src/page/plan.ts";
import { AppRoute } from "../src/route.ts";
import { UNKNOWN_OUTCOME, update } from "../src/update.ts";
import { view } from "../src/view.ts";
import { ana, errorsOf, plan, signedIn, today } from "./fixture.ts";

const planId = Option.getOrThrow(Option.fromNullishOr(plan.planId));
const withPlan: Model = { ...signedIn, plan: LivePlan.Success({ data: Option.some(plan) }) };

const move = Write.MoveSession({
  target: planId,
  input: { sessionId: SessionId.make("2026-11-10"), toDay: Day.make("2026-11-14") },
});

/** The model with the athlete's move filled in and sent: the first command id of the page is `s:0`. */
const moveSent = (() => {
  const filled = [
    Message.UpdatedMove({ field: "sessionId", value: "2026-11-10" }),
    Message.UpdatedMove({ field: "toDay", value: "2026-11-14" }),
    Message.SubmittedMove(),
  ].reduce((m, message) => update(m, message).model, withPlan);
  return filled;
})();

const moveResult = (result: typeof PlanningClient.Message.Type) => Message.ReceivedPlanningResult({ result });

describe("sending a write", () => {
  it("sends the domain command once, and resends the same one when its outcome is unknown", () =>
    Story.story(
    update,
    Story.given(withPlan),
    Story.message(Message.UpdatedMove({ field: "sessionId", value: "2026-11-10" })),
    Story.message(Message.UpdatedMove({ field: "toDay", value: "2026-11-14" })),
    Story.message(Message.SubmittedMove()),
    // Exactly the domain command, with the page's first command id.
    Story.Command.expectExact(commandFor(move, "s:0")),
    Story.model((model) => {
      expect(Option.getOrNull(model.inFlight)).toEqual({ write: move, commandId: "s:0", outcome: "sending" });
    }),
    Story.Command.resolve(
      PlanningClient.MoveSession({ target: move.target, input: move.input, commandId: "s:0" }),
      PlanningClient.Message.FailedMoveSession({ commandId: "s:0", failure: { _tag: "Unknown" } }),
    ),
    Story.model((model) => {
      expect(Option.getOrNull(model.inFlight)?.outcome).toBe("unknown");
      expect(Option.getOrNull(model.error)).toBe(UNKNOWN_OUTCOME);
    }),
    // Retrying resends the very same command: the same id, so the domain applies it once.
    Story.message(Message.ClickedRetryWrite()),
    Story.Command.expectExact(commandFor(move, "s:0")),
    Story.Command.resolve(
      PlanningClient.MoveSession({ target: move.target, input: move.input, commandId: "s:0" }),
      PlanningClient.Message.SucceededMoveSession({ commandId: "s:0", reply: undefined, receipt: { stream: planId, version: 3 } }),
    ),
    Story.model((model) => {
      expect(Option.isNone(model.inFlight)).toBe(true);
      expect(Option.getOrNull(model.notice)).toBe("Sesión movida.");
      expect(model.move).toEqual({ sessionId: FieldValidation.NotValidated({ value: "" }), toDay: FieldValidation.NotValidated({ value: "" }) });
      expect(model.commandIds.sent).toBe(1);
    }),
  ));

  it("sends nothing else while a write is in flight", () => {
    const again = update(moveSent, Message.SubmittedMove());
    expect(again.commands ?? []).toEqual([]);
    expect(again.model.inFlight).toEqual(moveSent.inFlight);
  });

  it("keeps the plan's forms closed while a write is in flight, and opens them when it settles", () => {
    expect(update(moveSent, Message.UpdatedMove({ field: "toDay", value: "2026-11-15" })).model).toBe(moveSent);
    expect(update(moveSent, Message.UpdatedRequirement({ field: "instructions", value: "Short day" })).model).toBe(moveSent);
    const settled = update(
      moveSent,
      moveResult(PlanningClient.Message.SucceededMoveSession({ commandId: "s:0", reply: undefined, receipt: { stream: planId, version: 3 } })),
    );
    expect(settled.model.move.toDay).toMatchObject({ value: "" });
    const reopened = update(settled.model, Message.UpdatedMove({ field: "toDay", value: "2026-11-15" })).model;
    expect(reopened.move.toDay).toMatchObject({ value: "2026-11-15" });
  });

  it("names a real rejection in the athlete's words and lets the next write go", () => {
    const rejected = update(
      moveSent,
      moveResult(
        PlanningClient.Message.FailedMoveSession({
          commandId: "s:0",
          failure: { _tag: "Rejected", rejection: new DayTaken({ day: Day.make("2026-11-14") }) },
        }),
      ),
    ).model;
    expect(Option.getOrNull(rejected.error)).toBe("El 2026-11-14 ya tiene otra sesión.");
    expect(Option.isNone(rejected.inFlight)).toBe(true);
    const next = update(rejected, Message.SubmittedMove());
    expect(next.commands?.map((c) => c.args)).toEqual([commandFor(move, "s:1").args]);
  });

  it("explains why a session taken over in Intervals can't move", () => {
    const next = update(
      moveSent,
      moveResult(
        PlanningClient.Message.FailedMoveSession({
          commandId: "s:0",
          failure: {
            _tag: "Rejected",
            rejection: new SessionNotMovable({ sessionId: SessionId.make("2026-11-11"), status: "changedInIntervals" }),
          },
        }),
      ),
    );
    expect(Option.getOrNull(next.model.error)).toBe("Esa sesión la cambiaste en Intervals.icu, que manda: muévela allí.");
  });

  it("signs out when the session is denied", () => {
    const next = update(
      moveSent,
      moveResult(PlanningClient.Message.FailedMoveSession({ commandId: "s:0", failure: { _tag: "Denied", error: new Unauthorized() } })),
    ).model;
    expect(next.athleteId).toBeNull();
    expect(Option.isNone(next.inFlight)).toBe(true);
    expect(next.plan).toEqual(AsyncData.Idle());
    expect(Option.getOrNull(next.error)).toBe("Tu sesión ha terminado. Vuelve a conectar con Intervals.icu.");
  });

  it("ignores a result for another command", () => {
    const next = update(
      moveSent,
      moveResult(PlanningClient.Message.FailedMoveSession({ commandId: "old:7", failure: { _tag: "Unknown" } })),
    );
    expect(next.model).toBe(moveSent);
  });

  it("retires the plan from the athlete's local day, and explains an implausible one", () => {
    const sent = update(update(withPlan, Message.ClickedRetire()).model, Message.ClickedConfirmRetire());
    expect(sent.commands?.map((c) => [c.name, c.args])).toEqual([
      ["RetirePlan", { target: planId, input: { today }, commandId: "s:0" }],
    ]);
    const refused = update(
      sent.model,
      Message.ReceivedPlanningResult({
        result: PlanningClient.Message.FailedRetirePlan({
          commandId: "s:0",
          failure: { _tag: "Rejected", rejection: new ImplausibleToday({ today }) },
        }),
      }),
    );
    expect(Option.getOrNull(refused.model.error)).toBe(
      "La fecha de este dispositivo no cuadra con la de Cadencia. Revisa la fecha y la hora.",
    );
  });

  it("answers an intent in the conversation it belongs to, with today", () => {
    const october = conversationIdFor(ana, YearMonth.make("2026-10"));
    const messageId = MessageId.make("7c9e6679-7425-40de-944b-e07fc1f90ae7");
    const sent = update(signedIn, Message.ClickedAcceptIntent({ conversationId: october, messageId }));
    expect(sent.commands?.map((c) => [c.name, c.args])).toEqual([
      ["AcceptIntent", { target: october, input: { messageId, today }, commandId: "s:0" }],
    ]);
    const expired = update(
      sent.model,
      Message.ReceivedCoachResult({
        result: CoachClient.Message.FailedAcceptIntent({
          commandId: "s:0",
          failure: { _tag: "Rejected", rejection: new IntentExpired({ messageId }) },
        }),
      }),
    );
    expect(Option.getOrNull(expired.model.error)).toBe("Esa propuesta era para días que ya han pasado.");
  });

  it("says what each field is missing instead of sending an incomplete move", () => {
    const next = update(withPlan, Message.SubmittedMove());
    expect(next.model.move.sessionId).toEqual(FieldValidation.Invalid({ value: "", errors: ["Elige una sesión."] }));
    expect(next.model.move.toDay).toEqual(FieldValidation.Invalid({ value: "", errors: ["Elige el día nuevo."] }));
    expect(next.commands ?? []).toEqual([]);
  });

  it("checks a field as the athlete fills it in", () => {
    const typed = update(withPlan, Message.UpdatedMove({ field: "toDay", value: "2026-11-14" })).model;
    expect(typed.move.toDay).toEqual(FieldValidation.Valid({ value: "2026-11-14" }));
    expect(typed.move.sessionId).toEqual(FieldValidation.NotValidated({ value: "" }));
  });

  it("sends a day's requirement with no limit when the minutes are left blank, and refuses a fraction", () => {
    const filled = [
      Message.UpdatedRequirement({ field: "day", value: "2026-11-12" }),
      Message.UpdatedRequirement({ field: "instructions", value: "  Solo rodillo  " }),
    ].reduce((m, message) => update(m, message).model, withPlan);
    const fraction = update(update(filled, Message.UpdatedRequirement({ field: "maxMinutes", value: "45.5" })).model, Message.SubmittedRequirement());
    expect(Option.getOrNull(errorsOf(fraction.model.requirement.maxMinutes))).toEqual(["Un número entero de minutos, de 0 a 1440."]);
    expect(fraction.commands ?? []).toEqual([]);
    const sent = update(filled, Message.SubmittedRequirement());
    expect(sent.commands?.map((c) => c.name)).toEqual(["RecordDayRequirement"]);
    expect(Option.getOrNull(sent.model.inFlight)?.write).toEqual(
      Write.RecordDayRequirement({
        target: planId,
        input: { day: Day.make("2026-11-12"), instructions: Paragraph.make("Solo rodillo"), maxMinutes: null },
      }),
    );
  });

  it("shows each field's reason under it", () =>
    Scene.scene(
      { update, view },
      Scene.given({ ...withPlan, route: AppRoute.Plan() }),
      Scene.click(Scene.role("button", { name: "Mover" })),
      Scene.expect(Scene.text("Elige una sesión.")).toExist(),
      Scene.expect(Scene.text("Elige el día nuevo.")).toExist(),
    ));

  it("asks before retiring the plan", () => {
    const asked = update(withPlan, Message.ClickedRetire());
    expect(asked.model.confirmRetire).toBe(true);
    expect(update(asked.model, Message.ClickedCancelRetire()).model.confirmRetire).toBe(false);
  });

  it("offers only the sessions the plan lets the athlete move", () => {
    expect(plan.sessions.filter(isMovable).map((s) => s.sessionId)).toEqual(["2026-11-10", "2026-11-13"]);
  });
});
