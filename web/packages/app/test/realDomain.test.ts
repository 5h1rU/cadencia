import { AthletePlanningApi } from "@cadencia/planning/AthletePlanningApi.api";
import type { CurrentPlanState } from "@cadencia/planning/Plan/CurrentPlan.view";
import type * as Domain from "@alchemy.run/domain";
import { expect, it } from "@effect/vitest";
import * as Effect from "effect/Effect";
import * as Option from "effect/Option";
import * as Stream from "effect/Stream";
import { Message } from "../src/message.ts";
import type { Model } from "../src/model.ts";
import { update } from "../src/update.ts";
import { createPlan, PlanningInMemory } from "./domain.ts";
import { ana, signedIn } from "./fixture.ts";

type Plan = typeof CurrentPlanState.Type;

/**
 * The plan as the real `CurrentPlan` view comes to show it, received the way
 * the app's subscription delivers it. A view follows its events, so the app
 * waits for the snapshot that shows the change, as it does in the browser.
 */
const receivePlan = (model: Model, shows: (plan: Plan) => boolean) =>
  Effect.gen(function* () {
    const planning = yield* AthletePlanningApi.Client;
    const plan = yield* planning.CurrentPlan.watch(ana).pipe(
      Stream.map(({ state }) => state),
      Stream.filter((state): state is Plan => state !== null && shows(state)),
      Stream.runHead,
    );
    return update(model, Message.ReceivedPlan({ plan })).model;
  });

const daysOf = (model: Model) =>
  model.plan._tag === "Success" ? Option.getOrThrow(model.plan.data).sessions.map((s) => s.day) : [];

/** Fill in the move form and submit it; then run the one Command the app sends against the real model. */
const move = (model: Model, sessionId: string, toDay: string) =>
  Effect.gen(function* () {
    const filled = [
      Message.UpdatedMove({ field: "sessionId", value: sessionId }),
      Message.UpdatedMove({ field: "toDay", value: toDay }),
    ].reduce((m, message) => update(m, message).model, model);
    const submitted = update(filled, Message.SubmittedMove());
    expect(submitted.commands?.map((c) => c.name)).toEqual(["MoveSession"]);
    // The app's Commands may use either Api; a move uses Planning's alone.
    const send = submitted.commands![0]!.effect as Effect.Effect<Message, never, Domain.Api.ClientKey<"AthletePlanningApi">>;
    return update(submitted.model, yield* send).model;
  });

it.live("a move the app sends is decided by the real Plan, and the app shows what it said", () =>
  Effect.gen(function* () {
    yield* createPlan;
    const opened = yield* receivePlan(signedIn, (plan) => plan.status === "active");
    expect(daysOf(opened)).toEqual(["2026-11-09", "2026-11-10", "2026-11-14"]);

    // Tuesday's session to the free Wednesday: the aggregate accepts, and the view the app watches moves it.
    const moved = yield* move(opened, "2026-11-10", "2026-11-11");
    expect(Option.getOrNull(moved.notice)).toBe("Sesión movida.");
    expect(Option.isNone(moved.inFlight)).toBe(true);
    const after = yield* receivePlan(moved, (plan) => plan.sessions.some((s) => s.day === "2026-11-11"));
    expect(daysOf(after)).toEqual(["2026-11-09", "2026-11-11", "2026-11-14"]);

    // Onto Saturday, which is taken: the aggregate's own rejection, in the athlete's words.
    const refused = yield* move(after, "2026-11-10", "2026-11-14");
    expect(Option.getOrNull(refused.error)).toBe("El 2026-11-14 ya tiene otra sesión.");
    expect(Option.isNone(refused.inFlight)).toBe(true);
  }).pipe(Effect.scoped, Effect.provide(PlanningInMemory)),
);
