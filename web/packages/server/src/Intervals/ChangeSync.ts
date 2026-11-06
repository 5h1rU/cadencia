import { system } from "@cadencia/kernel/Actor";
import type { AthleteId } from "@cadencia/kernel/Athlete.id";
import { addDays, Day } from "@cadencia/kernel/Day";
import { AthletePlanningApi } from "@cadencia/planning/AthletePlanningApi.api";
import { IntervalsSyncApi } from "@cadencia/planning/IntervalsSyncApi.api";
import { PlanId } from "@cadencia/planning/Plan/Plan.id";
import type { PlannedSession } from "@cadencia/planning/Plan/PlanShape";
import * as Effect from "effect/Effect";
import * as Option from "effect/Option";
import { Connections } from "../Connections.ts";
import { overPlanning } from "../Hosting.ts";
import { actingAs } from "../Session.ts";
import { calendarEntry } from "./IntervalsCalendar.ts";
import { athletePath, callIntervals, type IntervalsEvent } from "./IntervalsHttp.ts";

/** What changed about a published session, if the athlete touched it in Intervals. */
export const changeOf = (session: PlannedSession, event: IntervalsEvent | undefined): "changed" | "removed" | null => {
  if (!event) return "removed";
  const expected = calendarEntry(session);
  const sameDay = (event.start_date_local ?? "").slice(0, 10) === session.day;
  const sameName = (event.name ?? "") === expected.name;
  const sameTime = Math.abs((event.moving_time ?? 0) - expected.moving_time) < 60;
  return sameDay && sameName && sameTime ? null : "changed";
};

/**
 * Compare one athlete's published sessions with their Intervals calendar and
 * record what they changed or removed there. Intervals wins.
 */
export const syncAthlete = (athleteId: AthleteId, today: Day) =>
  Effect.gen(function* () {
    const connection = yield* (yield* Connections).find(athleteId);
    if (Option.isNone(connection)) return;
    const planning = yield* overPlanning(AthletePlanningApi.clientInProcess).pipe(Effect.provide(actingAs(system("IntervalsSync"))));
    const sync = yield* overPlanning(IntervalsSyncApi.clientInProcess).pipe(Effect.provide(actingAs(system("IntervalsSync"))));
    const plan = yield* planning.CurrentPlan.get(athleteId).pipe(Effect.orDie);
    if (!plan || plan.status !== "active" || !plan.planId || !plan.endDay) return;
    const watched = plan.sessions.filter((s) => s.status === "published" && s.day >= addDays(today, -1));
    if (watched.length === 0) return;
    const events = yield* callIntervals(connection.value.token, "GET", athletePath(athleteId, "/events.json"), {
      query: { oldest: addDays(today, -1), newest: plan.endDay },
    }).pipe(Effect.orDie);
    const byExternalId = new Map(
      (Array.isArray(events) ? (events as Array<IntervalsEvent>) : [])
        .filter((e) => e.external_id)
        .map((e) => [e.external_id!, e]),
    );
    for (const session of watched) {
      const change = changeOf(session, byExternalId.get(session.externalId));
      if (change === null) continue;
      yield* sync.RecordExternalChange(
        PlanId.make(plan.planId),
        { externalId: session.externalId, change },
        { commandId: `sync:${session.externalId}:${change}` },
      );
    }
  }).pipe(Effect.scoped);

/** Every connected athlete, one after another; one athlete's failure doesn't stop the rest. */
export const syncAll = (today: Day) =>
  Effect.gen(function* () {
    const athletes = yield* (yield* Connections).athletes;
    yield* Effect.forEach(
      athletes,
      (athleteId) => syncAthlete(athleteId, today).pipe(Effect.catchCause((cause) => Effect.logWarning("Intervals sync failed", athleteId, cause))),
      { discard: true },
    );
  });
