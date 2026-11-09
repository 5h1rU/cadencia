import { athlete } from "@cadencia/identity/Actor";
import { AthleteId } from "@cadencia/identity/Athlete.id";
import { EntityKey } from "@cadencia/kernel/EntityKey";
import { planIdFor } from "@cadencia/kernel/Plan.id";
import { CoachPlanningApi } from "@cadencia/planning/CoachPlanningApi.api";
import { IntervalsSyncApi } from "@cadencia/planning/IntervalsSyncApi.api";
import { CreatePlan } from "@cadencia/planning/Plan/CreatePlan.command";
import { afterEach, describe, expect, it, vi } from "@effect/vitest";
import * as Effect from "effect/Effect";
import * as Redacted from "effect/Redacted";
import * as Schema from "effect/Schema";
import * as Stream from "effect/Stream";
import { Connections } from "../src/Connections.ts";
import { overPlanning } from "../src/Hosting.ts";
import { calendarEntry } from "../src/Intervals/IntervalsCalendar.ts";
import { actingAs } from "../src/Session.ts";
import { inWorker, serve, WEBHOOK_SECRET } from "./worker.ts";

const anaId = AthleteId.make("i100");
const planId = planIdFor(anaId, EntityKey.make("0b6f5a2e-1c3d-4e5f-8a9b-0c1d2e3f4a5b"));

const connect = Effect.gen(function* () {
  yield* (yield* Connections).save({ athleteId: anaId, token: Redacted.make("token"), scopes: ["CALENDAR:WRITE"] });
});

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
        { day: "2026-11-10", kind: "threshold", title: "Threshold", targetMinutes: 75, purpose: "Threshold work" },
        { day: "2026-11-14", kind: "longRide", title: "Long ride", targetMinutes: 180, purpose: "Durability" },
      ],
    });
    return planning.CreatePlan(planId, input);
  }),
);

const syncView = overPlanning(IntervalsSyncApi.clientInProcess).pipe(Effect.provide(actingAs({ _tag: "System", name: "IntervalsSync" })));

const statuses = syncView.pipe(
  Effect.flatMap((sync) => sync.CurrentPlan.get(anaId)),
  Effect.map((plan) => plan?.sessions.map((s) => s.status)),
);

/** Wait until the plan's sessions are all in Intervals, and return them. */
const published = syncView.pipe(
  Effect.flatMap((sync) =>
    sync.CurrentPlan.watch(anaId).pipe(
      Stream.map(({ state }) => state),
      Stream.filter((p) => p !== null && p.sessions.length > 0 && p.sessions.every((s) => s.status === "published")),
      Stream.runHead,
    ),
  ),
  Effect.map((plan) => (plan._tag === "Some" && plan.value ? plan.value.sessions : [])),
);

/** Intervals.icu delivers a webhook, as it does: the app's secret and the events. */
const deliver = (events: ReadonlyArray<object>, secret = WEBHOOK_SECRET) =>
  serve("/webhooks/intervals", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ secret, events }),
  });

/** Answer Intervals' events request with `events`, and count the calls. */
const intervalsShows = (events: ReadonlyArray<object>) =>
  vi.spyOn(globalThis, "fetch").mockImplementation(async () => new Response(JSON.stringify(events), { status: 200 }));

afterEach(() => vi.restoreAllMocks());

describe("Intervals.icu webhooks", () => {
  it.live("a changed calendar takes over what the athlete moved or deleted, once, and leaves the rest", () =>
    inWorker(
      Effect.gen(function* () {
        yield* connect;
        yield* createPlan;
        const sessions = yield* published;
        expect(sessions).toHaveLength(3);
        const [easy, threshold] = sessions.map((s) => ({ id: 1, ...calendarEntry(s) }));
        // Easy stays as published; the threshold moved to Wednesday; the long ride is gone.
        const fetch = intervalsShows([easy, { ...threshold, start_date_local: "2026-11-11T00:00:00" }]);

        // Intervals sometimes sends the athlete's id without its "i".
        const delivered = yield* deliver([{ athlete_id: "100", type: "CALENDAR_UPDATED", events: [], deleted_events: [] }]);
        expect(delivered.status).toBe(200);
        expect(fetch).toHaveBeenCalledTimes(1);
        expect(yield* statuses).toEqual(["published", "changedInIntervals", "removedInIntervals"]);

        // A repeated delivery reads Intervals again and finds nothing new.
        expect((yield* deliver([{ athlete_id: "i100", type: "CALENDAR_UPDATED" }])).status).toBe(200);
        expect(yield* statuses).toEqual(["published", "changedInIntervals", "removedInIntervals"]);

        // The session the athlete took over is still watched: deleting it later is noticed too.
        vi.restoreAllMocks();
        intervalsShows([easy]);
        expect((yield* deliver([{ athlete_id: "i100", type: "CALENDAR_UPDATED" }])).status).toBe(200);
        expect(yield* statuses).toEqual(["published", "removedInIntervals", "removedInIntervals"]);
      }),
    ),
  );

  it.live("an edited workout is the athlete's, even with the same name and duration", () =>
    inWorker(
      Effect.gen(function* () {
        yield* connect;
        yield* createPlan;
        const [easy, threshold, long] = (yield* published).map((s) => ({ id: 1, ...calendarEntry(s) }));
        intervalsShows([easy, { ...threshold, description: "4x8m 105%" }, long]);
        expect((yield* deliver([{ athlete_id: "i100", type: "CALENDAR_UPDATED" }])).status).toBe(200);
        expect(yield* statuses).toEqual(["published", "changedInIntervals", "published"]);
      }),
    ),
  );

  it.live("a revoked authorization reads nothing and takes nothing over; an outage asks Intervals to deliver again", () =>
    inWorker(
      Effect.gen(function* () {
        yield* connect;
        yield* createPlan;
        yield* published;
        // Both are reported as errors, by id, status and kind, without what Intervals answered.
        const failure = { message: "Intervals call failed", operation: "syncCalendar", athleteId: "i100" };
        const reported = () => vi.spyOn(console, "error").mockImplementation(() => {});
        const revoked = vi
          .spyOn(globalThis, "fetch")
          .mockImplementation(async () => new Response("unauthorized", { status: 401 }));
        const letGo = reported();
        expect((yield* deliver([{ athlete_id: "i100", type: "CALENDAR_UPDATED" }])).status).toBe(200);
        expect(revoked).toHaveBeenCalledTimes(1);
        expect(letGo.mock.calls).toEqual([[{ ...failure, status: 401, kind: "notConnected" }]]);
        expect(yield* statuses).toEqual(["published", "published", "published"]);

        vi.restoreAllMocks();
        vi.spyOn(globalThis, "fetch").mockImplementation(async () => new Response("down", { status: 503 }));
        const outage = reported();
        expect((yield* deliver([{ athlete_id: "i100", type: "CALENDAR_UPDATED" }])).status).toBe(503);
        expect(outage.mock.calls).toEqual([[{ ...failure, status: 503, kind: "unavailable" }]]);
        expect(yield* statuses).toEqual(["published", "published", "published"]);

        // An answer that isn't a calendar says nothing was removed.
        vi.restoreAllMocks();
        vi.spyOn(globalThis, "fetch").mockImplementation(async () => new Response(JSON.stringify({ error: "x" }), { status: 200 }));
        expect((yield* deliver([{ athlete_id: "i100", type: "CALENDAR_UPDATED" }])).status).toBe(200);
        expect(yield* statuses).toEqual(["published", "published", "published"]);
      }),
    ),
  );

  it.live("only Intervals, with the app's secret, can make Cadencia read a calendar", () =>
    inWorker(
      Effect.gen(function* () {
        yield* connect;
        const fetch = vi.spyOn(globalThis, "fetch");
        const refused = yield* deliver([{ athlete_id: "i100", type: "CALENDAR_UPDATED" }], "not-the-secret");
        expect(refused.status).toBe(401);
        expect((yield* deliver([{ athlete_id: "i100" }])).status).toBe(400);
        expect(fetch).not.toHaveBeenCalled();
      }),
    ),
  );

  it.live("other events, and athletes who aren't connected, read nothing", () =>
    inWorker(
      Effect.gen(function* () {
        const fetch = vi.spyOn(globalThis, "fetch");
        const delivered = yield* deliver([
          { athlete_id: "i100", type: "ACTIVITY_UPLOADED", activity: { id: "i1" } },
          { athlete_id: "i200", type: "CALENDAR_UPDATED" },
        ]);
        expect(delivered.status).toBe(200);
        expect(fetch).not.toHaveBeenCalled();
      }),
    ),
  );
});
