import { Calendar } from "@cadencia/planning/Plan/Calendar.external";
import type { PlannedSession } from "@cadencia/planning/Plan/PlanShape";
import type { RuntimeContext } from "alchemy/RuntimeContext";
import * as Effect from "effect/Effect";
import * as Option from "effect/Option";
import { Connections } from "../Connections.ts";
import { athletePath, callIntervals } from "./IntervalsHttp.ts";
import { workoutText } from "./WorkoutText.ts";

/**
 * External system operations are typed without requirements, but they only
 * ever run inside a policy, and every platform provides `RuntimeContext` (the
 * Worker's bindings, such as D1) to the handlers it runs. This states that.
 */
const inHandler = <A, E>(effect: Effect.Effect<A, E, RuntimeContext>) =>
  effect as unknown as Effect.Effect<A, E, never>;

/** The calendar entry Intervals shows for a planned session. */
export const calendarEntry = (session: PlannedSession) => ({
  category: "WORKOUT",
  start_date_local: `${session.day}T00:00:00`,
  name: session.workout?.name ?? session.title,
  type: "Ride",
  external_id: session.externalId,
  uid: session.externalId,
  tags: [`cadencia:${session.kind}`],
  moving_time: Math.round(
    session.workout ? session.workout.steps.reduce((s, step) => s + step.durationSeconds, 0) : session.targetMinutes * 60,
  ),
  description: session.workout ? workoutText(session.workout) : session.purpose,
});

/**
 * The Calendar external system over Intervals.icu. Upserts by `external_id`
 * (with OAuth, Intervals updates this app's event with the same id instead of
 * duplicating it) and deletes by `external_id`.
 */
export const IntervalsCalendar = Calendar.toLayer(
  Effect.gen(function* () {
    const connections = yield* Connections;
    const tokenFor = (athleteId: Parameters<typeof connections.find>[0]) =>
      inHandler(connections.find(athleteId)).pipe(
        Effect.flatMap(
          Option.match({
            onNone: () => Effect.die(new Error(`No Intervals connection for ${athleteId}`)),
            onSome: (c) => Effect.succeed(c.token),
          }),
        ),
      );
    return {
      publishSession: ({ athleteId, session }) =>
        Effect.gen(function* () {
          const token = yield* tokenFor(athleteId);
          const result = yield* callIntervals(token, "POST", athletePath(athleteId, "/events/bulk"), {
            query: { upsert: "true" },
            body: [calendarEntry(session)],
          }).pipe(Effect.orDie);
          const events = Array.isArray(result) ? (result as Array<{ id?: number }>) : [];
          return { eventId: events[0]?.id ?? 0 };
        }),
      withdrawSession: ({ athleteId, externalId }) =>
        Effect.gen(function* () {
          const token = yield* tokenFor(athleteId);
          yield* callIntervals(token, "PUT", athletePath(athleteId, "/events/bulk-delete"), {
            body: [{ external_id: externalId }],
          }).pipe(Effect.orDie);
          return { withdrawn: true };
        }),
    };
  }),
);
