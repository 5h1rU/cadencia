import { system } from "@cadencia/identity/Actor";
import type { AthleteId } from "@cadencia/identity/Athlete.id";
import { addDays, type Day } from "@cadencia/kernel/Calendar/Day";
import { IntervalsSyncApi } from "@cadencia/planning/IntervalsSyncApi.api";
import type { PlannedSession } from "@cadencia/planning/Plan/PlannedSession";
import * as Effect from "effect/Effect";
import * as Option from "effect/Option";
import * as Schema from "effect/Schema";
import { Connections } from "../Connections.ts";
import { overPlanning } from "../Hosting.ts";
import { actingAs } from "../Session.ts";
import { calendarEntry } from "./IntervalsCalendar.ts";
import { athletePath, callIntervals, IntervalsEvent, kindOf } from "./IntervalsHttp.ts";
import { CalendarSyncUnavailable } from "./IntervalsWebhook.ts";

/** Text as the athlete reads it: line endings and spacing at the ends of lines don't change it. */
const normalized = (text: string | null | undefined) =>
  (text ?? "")
    .replace(/\r\n?/g, "\n")
    .split("\n")
    .map((line) => line.trimEnd())
    .join("\n")
    .trim();

/**
 * What changed about a session Cadencia published, if the athlete touched it
 * in Intervals: anything Cadencia wrote (day, name, duration, the workout in
 * the description) that no longer reads the same.
 */
export const changeOf = (session: PlannedSession, event: IntervalsEvent | undefined): "changed" | "removed" | null => {
  if (!event) return "removed";
  const expected = calendarEntry(session);
  const sameDay = (event.start_date_local ?? "").slice(0, 10) === session.day;
  const sameName = (event.name ?? "") === expected.name;
  const sameTime = Math.abs((event.moving_time ?? 0) - expected.moving_time) < 60;
  const sameWorkout = normalized(event.description) === normalized(expected.description);
  return sameDay && sameName && sameTime && sameWorkout ? null : "changed";
};

/**
 * What the sync records about a session: a published one may have been
 * changed or removed; one the athlete already changed can still be removed.
 */
const observedChange = (session: PlannedSession, event: IntervalsEvent | undefined) => {
  if (session.status === "changedInIntervals") return event ? null : ("removed" as const);
  return changeOf(session, event);
};

/**
 * Compare one athlete's sessions in Intervals with the plan and record what
 * they changed or removed there. Intervals wins. Intervals' CALENDAR_UPDATED
 * webhook runs it; it reads the calendar again, so a repeated or late delivery
 * changes nothing.
 *
 * An athlete whose authorization was revoked has nothing to sync until they
 * connect again, and an answer that can't be read won't read better later:
 * both are let go. An outage fails with `CalendarSyncUnavailable`, so the
 * delivery comes again.
 */
export const syncAthlete = (athleteId: AthleteId, today: Day) =>
  Effect.gen(function* () {
    const connection = yield* (yield* Connections).find(athleteId);
    if (Option.isNone(connection)) return;
    const sync = yield* overPlanning(IntervalsSyncApi.clientInProcess).pipe(Effect.provide(actingAs(system("IntervalsSync"))));
    const plan = yield* sync.CurrentPlan.get(athleteId).pipe(Effect.orDie);
    if (!plan || plan.status !== "active" || !plan.planId || !plan.endDay) return;
    const watched = plan.sessions.filter(
      (s) => (s.status === "published" || s.status === "changedInIntervals") && s.day >= addDays(today, -1),
    );
    if (watched.length === 0) return;
    const answer = yield* callIntervals(connection.value.token, "GET", athletePath(athleteId, "/events.json"), {
      query: { oldest: addDays(today, -1), newest: plan.endDay },
    }).pipe(
      Effect.map(Option.some),
      Effect.catchTag("IntervalsError", (error) =>
        kindOf(error) === "unavailable" ? Effect.fail(new CalendarSyncUnavailable()) : Effect.succeed(Option.none()),
      ),
    );
    // A calendar that can't be read says nothing about what is in it: no session counts as removed.
    const events = Option.flatMap(answer, Schema.decodeUnknownOption(Schema.Array(IntervalsEvent)));
    if (Option.isNone(events)) return;
    const byExternalId = new Map(events.value.filter((e) => e.external_id).map((e) => [e.external_id!, e]));
    for (const session of watched) {
      const change = observedChange(session, byExternalId.get(session.externalId));
      if (change === null) continue;
      // Each observation carries the session as compared: the plan ignores one that no longer
      // applies (a session moved or published again since this read), so it needs no id of its own.
      yield* sync
        .RecordExternalChange(plan.planId, { externalId: session.externalId, change, observed: session })
        .pipe(Effect.orDie);
    }
  }).pipe(Effect.scoped);
