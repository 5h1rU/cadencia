import { conversationIdFor, YearMonth } from "@cadencia/coach/Conversation/Conversation.id";
import { dailyDecisionIdFor } from "@cadencia/coach/DailyDecision/DailyDecision.id";
import { NotYours } from "@cadencia/identity/NotYours.rejection";
import { Unauthorized } from "@cadencia/identity/Session.middleware";
import { Day } from "@cadencia/kernel/Calendar/Day";
import { describe, expect, it } from "@effect/vitest";
import * as Option from "effect/Option";
import { RpcClientDefect, RpcClientError } from "effect/rpc/RpcClientError";
import { AsyncData } from "foldkit";
import * as Scene from "foldkit/scene";
import { backoffSeconds, WaitToReconnect } from "../src/command.ts";
import { Message } from "../src/message.ts";
import { LiveDecision, LivePlan, Model } from "../src/model.ts";
import { AppRoute } from "../src/route.ts";
import { readFailed, subscriptions } from "../src/subscription.ts";
import { update } from "../src/update.ts";
import { view } from "../src/view.ts";
import { ana, signedIn, signedOut, today, wellFormed } from "./fixture.ts";

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
      Scene.given({ ...signedIn, route: AppRoute.Plan() }),
      Scene.expect(Scene.text("Cargando…")).toExist(),
      Scene.expect(Scene.text("Sin plan")).not.toExist(),
    ));

  it('show "no plan" once the snapshot says so', () =>
    Scene.scene(
      { update, view },
      Scene.given({ ...signedIn, route: AppRoute.Plan(), plan: LivePlan.Success({ data: Option.none() }) }),
      Scene.expect(Scene.text("Sin plan")).toExist(),
      Scene.expect(Scene.text("Cargando…")).not.toExist(),
    ));
});
