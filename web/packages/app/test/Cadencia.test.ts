import { conversationIdFor, YearMonth } from "@cadencia/coach/Conversation/Conversation.id";
import { IntentExpired } from "@cadencia/coach/Conversation/AcceptIntent.command";
import { MessageId } from "@cadencia/coach/Conversation/Message.id";
import { dailyDecisionIdFor } from "@cadencia/coach/DailyDecision/DailyDecision.id";
import { AthleteId } from "@cadencia/identity/Athlete.id";
import { Unauthorized } from "@cadencia/identity/Session.middleware";
import { NotYours } from "@cadencia/identity/NotYours.rejection";
import { Day } from "@cadencia/kernel/Calendar/Day";
import { CurrentPlanState } from "@cadencia/planning/Plan/CurrentPlan.view";
import { ImplausibleToday } from "@cadencia/planning/Plan/ImplausibleToday.rejection";
import { DayTaken, SessionNotMovable } from "@cadencia/planning/Plan/MoveSession.command";
import { SessionId } from "@cadencia/planning/Plan/Session.id";
import { describe, expect, it } from "@effect/vitest";
import * as Duration from "effect/Duration";
import * as Option from "effect/Option";
import { RpcClientDefect, RpcClientError } from "effect/rpc/RpcClientError";
import * as Schema from "effect/Schema";
import * as Result from "effect/Result";
import { AsyncData } from "foldkit";
import * as Scene from "foldkit/scene";
import * as Story from "foldkit/story";
import {
  backoffSeconds,
  CoachClient,
  commandFor,
  declarationOf,
  History,
  init,
  IntervalsHistory,
  intervalsProblemOf,
  LiveDecision,
  LivePlan,
  isMovable,
  LoadIntervals,
  localDayOf,
  Message,
  type Model,
  PlanningClient,
  readFailed,
  subscriptions,
  UNKNOWN_OUTCOME,
  untilNextMidnight,
  update,
  view,
  WaitToReconnect,
  Write,
} from "../src/Cadencia.ts";

const ana = AthleteId.make("i100");
const today = Day.make("2026-11-09");
const signedIn = init({ athleteId: ana, today, session: "s" }).model;
const signedOut = init({ athleteId: null, today, session: "s" }).model;

const plan = Schema.decodeUnknownSync(CurrentPlanState)({
  planId: "i100:0b6f5a2e-1c3d-4e5f-8a9b-0c1d2e3f4a5b",
  status: "active",
  title: "Base de invierno",
  goal: "endurance",
  objective: "Llegar a marzo con 3 horas cómodas.",
  startDay: "2026-11-02",
  endDay: "2026-12-27",
  phases: [],
  longRideWeekday: null,
  event: null,
  sessions: [
    ["2026-11-10", "published"],
    ["2026-11-11", "changedInIntervals"],
    ["2026-11-12", "skipped"],
    ["2026-11-13", "provisional"],
  ].map(([day, status]) => ({
    sessionId: day,
    day,
    kind: "endurance",
    title: "Resistencia",
    targetMinutes: 60,
    purpose: "Base aeróbica.",
    status,
    workout: null,
    externalId: `cadencia-i100-0b6f5a2e-1c3d-4e5f-8a9b-0c1d2e3f4a5b-${day}`,
  })),
  requirements: [],
  calendarProblems: [{ sessionId: "2026-11-13", problem: "notConnected" }],
});
const planId = Option.getOrThrow(Option.fromNullishOr(plan.planId));
const withPlan: Model = { ...signedIn, plan: LivePlan.Success({ data: Option.some(plan) }) };

const move = Write.MoveSession({
  target: planId,
  input: { sessionId: SessionId.make("2026-11-10"), toDay: Day.make("2026-11-14") },
});

/** The model with the athlete's move filled in and sent: the first command id of the page is `s:0`. */
const moveSent = (() => {
  const filled = [
    Message.ChangedMove({ field: "sessionId", value: "2026-11-10" }),
    Message.ChangedMove({ field: "toDay", value: "2026-11-14" }),
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
    Story.message(Message.ChangedMove({ field: "sessionId", value: "2026-11-10" })),
    Story.message(Message.ChangedMove({ field: "toDay", value: "2026-11-14" })),
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
      expect(model.move).toEqual({ sessionId: "", toDay: "" });
      expect(model.commandIds.sent).toBe(1);
    }),
  ));

  it("sends nothing else while a write is in flight", () => {
    const again = update(moveSent, Message.SubmittedMove());
    expect(again.commands ?? []).toEqual([]);
    expect(again.model).toBe(moveSent);
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

  it("explains what's missing instead of sending an incomplete move", () => {
    const next = update(withPlan, Message.SubmittedMove());
    expect(Option.getOrNull(next.model.error)).toBe("Elige una sesión y un día nuevo.");
    expect(next.commands ?? []).toEqual([]);
  });

  it("asks before retiring the plan", () => {
    const asked = update(withPlan, Message.ClickedRetire());
    expect(asked.model.confirmRetire).toBe(true);
    expect(update(asked.model, Message.ClickedCancelRetire()).model.confirmRetire).toBe(false);
  });

  it("offers only the sessions the plan lets the athlete move", () => {
    expect(plan.sessions.filter(isMovable).map((s) => s.sessionId)).toEqual(["2026-11-10", "2026-11-13"]);
  });
});

/** Dependencies a subscription can restart on: they must decode with its own schema. */
const wellFormed = (schema: Schema.Top, value: unknown) =>
  Schema.decodeUnknownSync(schema as unknown as Schema.Codec<unknown, unknown, never>)(value);

describe("live reads", () => {
  it("are all off for a signed-out visitor, with well-formed keys", () => {
    for (const [name, entry] of Object.entries(subscriptions)) {
      const dependencies = entry.modelToDependencies(signedOut);
      expect(() => wellFormed(entry.dependenciesSchema, dependencies), name).not.toThrow();
      if (name !== "today") expect((dependencies as { isEnabled: boolean }).isEnabled, name).toBe(false);
    }
  });

  it("follow the signed-in athlete's own keys", () => {
    const dependencies = Object.fromEntries(
      Object.entries(subscriptions).map(([name, entry]) => {
        const value = entry.modelToDependencies(signedIn);
        wellFormed(entry.dependenciesSchema, value);
        return [name, value];
      }),
    );
    expect(dependencies).toEqual({
      today: { today },
      plan: { key: ana, isEnabled: true },
      decision: { key: dailyDecisionIdFor(ana, today), isEnabled: true },
      thread: { key: conversationIdFor(ana, YearMonth.make("2026-11")), isEnabled: true },
      profile: { key: ana, isEnabled: true },
    });
  });

  it("move to the new day's decision and month's conversation when the day changes", () => {
    const next = update(signedIn, Message.ChangedDay({ today: Day.make("2026-12-01") })).model;
    expect(subscriptions.decision.modelToDependencies(next).key).toBe("i100:2026-12-01");
    expect(subscriptions.thread.modelToDependencies(next).key).toBe("i100:2026-12");
    expect(subscriptions.today.modelToDependencies(next)).toEqual({ today: "2026-12-01" });
  });

  it("pause after a transport failure and come back after a backoff", () => {
    const lost = update(signedIn, readFailed("plan")(new RpcClientError({ reason: new RpcClientDefect({ message: "socket closed", cause: null }) })));
    expect(lost.model.readsOnline).toBe(false);
    expect(lost.commands?.map((c) => [c.name, c.args])).toEqual([["WaitToReconnect", { seconds: 1 }]]);
    expect(subscriptions.plan.modelToDependencies(lost.model).isEnabled).toBe(false);
    // Another watch failing meanwhile doesn't schedule a second reconnection.
    expect(update(lost.model, Message.LostReads()).commands ?? []).toEqual([]);
    const back = update(lost.model, Message.ReconnectedReads()).model;
    expect(subscriptions.plan.modelToDependencies(back).isEnabled).toBe(true);
    // Failing again waits longer, until a read works.
    expect(update(back, Message.LostReads()).commands?.map((c) => c.args)).toEqual([{ seconds: 2 }]);
    expect(update(back, Message.ReceivedPlan({ plan: Option.none() })).model.readRetries).toBe(0);
    expect([0, 1, 5, 6, 10].map(backoffSeconds)).toEqual([1, 2, 32, 60, 60]);
    expect(WaitToReconnect.name).toBe("WaitToReconnect");
  });

  it("treat Unauthorized as signed out, and NotYours as a refusal of that view only", () => {
    expect(readFailed("plan")(new Unauthorized())).toEqual(Message.SignedOut());
    expect(update(signedIn, readFailed("plan")(new Unauthorized())).model.athleteId).toBeNull();
    expect(readFailed("plan")(new NotYours())).toEqual(Message.RefusedRead({ view: "plan" }));
    const refused = update(signedIn, Message.RefusedRead({ view: "plan" })).model;
    expect(refused.plan).toEqual(AsyncData.fail("notYours"));
    expect(refused.decision).toEqual(AsyncData.Loading());
    expect(Option.isNone(refused.error)).toBe(true);
  });

  it("wait for their first snapshot when signed in, and aren't watched when signed out", () => {
    for (const view of [signedIn.plan, signedIn.decision, signedIn.thread, signedIn.profile]) {
      expect(view).toEqual(AsyncData.Loading());
    }
    for (const view of [signedOut.plan, signedOut.decision, signedOut.thread, signedOut.profile]) {
      expect(view).toEqual(AsyncData.Idle());
    }
  });

  it('take "no plan" as a snapshot, not as a wait', () => {
    expect(update(signedIn, Message.ReceivedPlan({ plan: Option.none() })).model.plan).toEqual(
      LivePlan.Success({ data: Option.none() }),
    );
  });

  it("wait again for the decision of a new day, and for the conversation of a new month", () => {
    const shown = (model: Model): Model => ({
      ...model,
      decision: LiveDecision.Success({ data: Option.none() }),
      thread: update(model, Message.ReceivedThread({ thread: { conversationId: conversationIdFor(ana, YearMonth.make("2026-11")), messages: [] } })).model.thread,
    });
    const tomorrow = update(shown(signedIn), Message.ChangedDay({ today: Day.make("2026-11-10") })).model;
    expect(tomorrow.decision).toEqual(AsyncData.Loading());
    expect(AsyncData.isSuccess(tomorrow.thread)).toBe(true);
    const december = update(shown(signedIn), Message.ChangedDay({ today: Day.make("2026-12-01") })).model;
    expect(december.thread).toEqual(AsyncData.Loading());
    // A last snapshot of November, arriving after the month changed, is ignored.
    const late = Message.ReceivedThread({ thread: { conversationId: conversationIdFor(ana, YearMonth.make("2026-11")), messages: [] } });
    expect(update(december, late).model).toBe(december);
  });

  it("say they are loading where the content will be, until the snapshot comes", () =>
    Scene.scene(
      { update, view },
      Scene.given(signedIn),
      Scene.click(Scene.role("button", { name: "Plan" })),
      Scene.expect(Scene.text("Cargando…")).toExist(),
      Scene.expect(Scene.text("Sin plan")).not.toExist(),
    ));

  it('show "no plan" once the snapshot says so', () =>
    Scene.scene(
      { update, view },
      Scene.given({ ...signedIn, section: "plan", plan: LivePlan.Success({ data: Option.none() }) }),
      Scene.expect(Scene.text("Sin plan")).toExist(),
      Scene.expect(Scene.text("Cargando…")).not.toExist(),
    ));
});

describe("the local day", () => {
  it("is the athlete's calendar day, and the next one starts just after local midnight", () => {
    const evening = new Date(2026, 10, 9, 23, 59, 0);
    expect(localDayOf(evening)).toBe("2026-11-09");
    expect(Duration.toMillis(untilNextMidnight(evening))).toBe(61_000);
    expect(localDayOf(new Date(evening.getTime() + Duration.toMillis(untilNextMidnight(evening))))).toBe("2026-11-10");
  });
});

describe("the Intervals.icu history", () => {
  const range = { oldest: Day.make("2026-10-13"), newest: Day.make("2026-11-09") };
  const load = LoadIntervals({ range });
  const read = Schema.decodeUnknownSync(IntervalsHistory)({
    activities: [],
    wellness: [],
    athlete: { name: "Ana", weight: 61, ftp: 230 },
  });
  const settled = (result: Result.Result<IntervalsHistory, "signedOut" | "notConnected" | "unavailable">, at = range) =>
    Message.SettledLoadIntervals({ range: at, result });

  it("is read for the last four weeks when a section shows it, and kept on screen while it refreshes", () =>
    Story.story(
      update,
      Story.given(signedIn),
      Story.message(Message.ClickedSection({ section: "history" })),
      Story.Command.expectExact(load),
      Story.model((model) => expect(model.history).toEqual(AsyncData.Loading())),
      Story.Command.resolve(load, settled(Result.succeed(read))),
      Story.model((model) => expect(model.history).toEqual(History.Success({ data: read }))),
      // Opening the profile reads it again, keeping what's on screen.
      Story.message(Message.ClickedSection({ section: "profile" })),
      Story.Command.expectExact(load),
      Story.model((model) => expect(model.history).toEqual(History.Refreshing({ data: read }))),
      // A refresh that fails keeps the data and says why.
      Story.Command.resolve(load, settled(Result.fail("unavailable"))),
      Story.model((model) => expect(model.history).toEqual(History.Stale({ error: "unavailable", data: read }))),
      Story.Command.expectNone(),
    ));

  // Story answers each Command before the next Message, so what happens while a read is under way is
  // stepped through update directly.
  it("isn't read again while a read is under way", () => {
    const loading = update(signedIn, Message.ClickedSection({ section: "history" })).model;
    const again = update(loading, Message.ClickedSection({ section: "profile" }));
    expect(again.commands ?? []).toEqual([]);
    expect(again.model.history).toEqual(AsyncData.Loading());
  });

  it("isn't read for a signed-out visitor, nor for a section that doesn't show it", () => {
    expect(update(signedOut, Message.ClickedSection({ section: "profile" })).commands ?? []).toEqual([]);
    expect(update(signedIn, Message.ClickedSection({ section: "plan" })).commands ?? []).toEqual([]);
  });

  it("ignores a late answer for four weeks that are no longer shown", () => {
    const tomorrow = { oldest: Day.make("2026-10-14"), newest: Day.make("2026-11-10") };
    const loading = update(signedIn, Message.ClickedSection({ section: "history" })).model;
    const moved = update(loading, Message.ChangedDay({ today: Day.make("2026-11-10") }));
    expect(moved.commands?.map((c) => [c.name, c.args])).toEqual([["LoadIntervals", { range: tomorrow }]]);
    const late = update(moved.model, settled(Result.succeed(read)));
    expect(late.model).toBe(moved.model);
    expect(update(late.model, settled(Result.succeed(read), tomorrow)).model.history).toEqual(History.Success({ data: read }));
  });

  it("signs out when the session is gone, and ignores an answer that arrives after", () => {
    const loading = update(signedIn, Message.ClickedSection({ section: "history" })).model;
    const gone = update(loading, settled(Result.fail("signedOut"))).model;
    expect(gone.athleteId).toBeNull();
    expect(gone.history).toEqual(AsyncData.Idle());
    expect(update(gone, settled(Result.succeed(read))).model).toBe(gone);
  });

  it("is read again after the day's wellness is saved", () => {
    const loaded: Model = { ...signedIn, history: History.Success({ data: read }) };
    const saved = update(loaded, Message.SavedDeclaration());
    expect(saved.commands?.map((c) => [c.name, c.args])).toEqual([["LoadIntervals", { range }]]);
    expect(saved.model.history).toEqual(History.Refreshing({ data: read }));
  });

  it("shows that it is reading, then why it couldn't, with a way to connect again", () =>
    Scene.scene(
      { update, view },
      Scene.given(signedIn),
      Scene.click(Scene.role("button", { name: "Historial" })),
      Scene.expect(Scene.text("Leyendo Intervals.icu…")).toExist(),
      Scene.Command.resolve(load, settled(Result.fail("notConnected"))),
      Scene.expect(Scene.text("Leyendo Intervals.icu…")).not.toExist(),
      Scene.expect(Scene.role("link", { name: "Conectar de nuevo" })).toExist(),
    ));
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

describe("the server's Intervals statuses, as the athlete reads them", () => {
  it("are signed out, not connected, or Intervals not answering", () => {
    expect(intervalsProblemOf(401)).toBe("signedOut");
    expect(intervalsProblemOf(409)).toBe("notConnected");
    expect(intervalsProblemOf(502)).toBe("unavailable");
    expect(intervalsProblemOf(500)).toBe("unavailable");
  });
});
