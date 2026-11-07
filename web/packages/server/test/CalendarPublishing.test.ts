import { athlete } from "@cadencia/identity/Actor";
import { AthleteId } from "@cadencia/identity/Athlete.id";
import { Day } from "@cadencia/kernel/Calendar/Day";
import { EntityKey } from "@cadencia/kernel/EntityKey";
import { planIdFor } from "@cadencia/kernel/Plan.id";
import { AthletePlanningApi } from "@cadencia/planning/AthletePlanningApi.api";
import { CoachPlanningApi } from "@cadencia/planning/CoachPlanningApi.api";
import { Calendar } from "@cadencia/planning/Plan/Calendar.external";
import { CreatePlan } from "@cadencia/planning/Plan/CreatePlan.command";
import type { PlannedSession } from "@cadencia/planning/Plan/PlannedSession";
import { SessionId } from "@cadencia/planning/Plan/Session.id";
import * as Domain from "@alchemy.run/domain";
import { describe, expect, it } from "@effect/vitest";
import * as Deferred from "effect/Deferred";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as Schema from "effect/Schema";
import * as Stream from "effect/Stream";
import { MemoryConnections } from "../src/Connections.ts";
import { overPlanning, PlanningHosted } from "../src/Hosting.ts";
import { actingAs } from "../src/Session.ts";
import { SessionKeyTest } from "./session.ts";

const anaId = AthleteId.make("i100");
const planId = planIdFor(anaId, EntityKey.make("0b6f5a2e-1c3d-4e5f-8a9b-0c1d2e3f4a5b"));
const monday = Day.make("2026-11-09");

/**
 * A calendar that holds Monday's write until the test lets it go, and keeps
 * every session it was asked to write, in order.
 */
const holdingCalendar = (holding: Deferred.Deferred<void>, release: Deferred.Deferred<void>, written: Array<PlannedSession>) =>
  Calendar.toLayer(
    Effect.succeed({
      publishSession: ({ session }) =>
        Effect.gen(function* () {
          if (session.day === monday && written.length === 0) {
            yield* Deferred.succeed(holding, undefined);
            yield* Deferred.await(release);
          }
          written.push(session);
          return { published: true };
        }),
      withdrawSession: () => Effect.succeed({ withdrawn: true }),
    }),
  );

const createPlan = overPlanning(CoachPlanningApi.clientInProcess).pipe(
  Effect.provide(actingAs(athlete(anaId))),
  Effect.flatMap((planning) => {
    const { _tag, ...input } = Schema.decodeUnknownSync(CreatePlan)({
      _tag: "CreatePlan",
      title: "Base block",
      goal: "endurance",
      objective: null,
      startDay: "2026-11-09",
      endDay: "2026-12-20",
      phases: [{ focus: "base", startWeek: 1, endWeek: 6, summary: "Aerobic base" }],
      longRideWeekday: 7,
      event: null,
      sessions: [
        { day: "2026-11-09", kind: "endurance", title: "Easy endurance", targetMinutes: 60, purpose: "Aerobic base" },
        { day: "2026-11-14", kind: "longRide", title: "Long ride", targetMinutes: 180, purpose: "Durability" },
      ],
    });
    return planning.CreatePlan(planId, input);
  }),
);

const athletePlanning = overPlanning(AthletePlanningApi.clientInProcess).pipe(Effect.provide(actingAs(athlete(anaId))));

describe("publishing the plan to Intervals.icu", () => {
  it.live("writes only what the plan still holds when the write runs, however late", () =>
    Effect.gen(function* () {
      const holding = yield* Deferred.make<void>();
      const release = yield* Deferred.make<void>();
      const written: Array<PlannedSession> = [];
      const world = PlanningHosted.pipe(
        Layer.provideMerge(Layer.mergeAll(MemoryConnections, SessionKeyTest)),
        Layer.provide(Layer.mergeAll(holdingCalendar(holding, release, written), Domain.InMemory)),
      );
      yield* Effect.gen(function* () {
        yield* createPlan;
        // The plan's sessions go out one by one; Monday's write is held.
        yield* Deferred.await(holding);
        const planning = yield* athletePlanning;
        yield* planning.MoveSession(planId, { sessionId: SessionId.make("2026-11-14"), toDay: Day.make("2026-11-15") });
        yield* Deferred.succeed(release, undefined);
        // Wait until every session is in Intervals.
        yield* planning.CurrentPlan.watch(anaId).pipe(
          Stream.filter(({ state }) => state !== null && state.sessions.every((s) => s.status === "published")),
          Stream.runHead,
        );
        // Saturday's version, from the plan's creation, was no longer the plan's when its turn came.
        expect(written.map((s) => s.day)).toEqual(["2026-11-09", "2026-11-15"]);
      }).pipe(Effect.scoped, Effect.provide(world)) as Effect.Effect<void>;
    }),
  );
});
