import { totalSeconds } from "@cadencia/kernel/Training/Workout";
import { Calendar, CalendarRefused, CalendarUnavailable } from "@cadencia/planning/Plan/Calendar.external";
import type { PlannedSession } from "@cadencia/planning/Plan/PlannedSession";
import type { RuntimeContext } from "alchemy/RuntimeContext";
import * as Effect from "effect/Effect";
import * as Option from "effect/Option";
import * as Schema from "effect/Schema";
import { Connections } from "../Connections.ts";
import { athletePath, callIntervals, type IntervalsError, IntervalsEventId } from "./IntervalsHttp.ts";
import { workoutText } from "./WorkoutText.ts";

/**
 * External system operations are typed without requirements, but they only
 * ever run inside a policy, and every platform provides `RuntimeContext` (the
 * Worker's bindings, such as D1) to the handlers it runs. This states that.
 */
const inHandler = <A, E>(effect: Effect.Effect<A, E, RuntimeContext>) => effect as unknown as Effect.Effect<A, E, never>;

/** The calendar entry Intervals shows for a planned session. */
export const calendarEntry = (session: PlannedSession) => ({
  category: "WORKOUT",
  start_date_local: `${session.day}T00:00:00`,
  name: session.workout?.name ?? session.title,
  type: "Ride",
  external_id: session.externalId,
  uid: session.externalId,
  tags: [`cadencia:${session.kind}`],
  moving_time: Math.round(session.workout ? totalSeconds(session.workout) : session.targetMinutes * 60),
  description: session.workout ? workoutText(session.workout) : session.purpose,
});

/** What Intervals answers to a bulk upsert: the events it wrote. */
const Upserted = Schema.Array(Schema.Struct({ id: IntervalsEventId }));

/**
 * Intervals' answer in the calendar's terms: an outage or rate limit may pass
 * (unavailable); a revoked or missing authorization means the athlete isn't
 * connected; any other refusal won't change by trying again.
 */
const calendarError = (error: IntervalsError): CalendarUnavailable | CalendarRefused =>
  error.status === 0 || error.status === 429 || error.status >= 500
    ? new CalendarUnavailable()
    : new CalendarRefused({ problem: error.status === 401 || error.status === 403 ? "notConnected" : "refused" });

/**
 * The Calendar external system over Intervals.icu. Upserts by `external_id`
 * (with OAuth, Intervals updates this app's event with the same id instead of
 * duplicating it) and deletes by `external_id`. An athlete who disconnected
 * Intervals has no token any more: the calendar refuses them as not connected.
 */
export const IntervalsCalendar = Calendar.toLayer(
  Effect.gen(function* () {
    const connections = yield* Connections;
    const tokenFor = (athleteId: Parameters<typeof connections.find>[0]) =>
      inHandler(connections.find(athleteId)).pipe(
        Effect.flatMap(
          Option.match({
            onNone: () => Effect.fail(new CalendarRefused({ problem: "notConnected" })),
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
          }).pipe(Effect.mapError(calendarError));
          return { published: Option.isSome(Schema.decodeUnknownOption(Upserted)(result)) };
        }),
      withdrawSession: ({ athleteId, externalId }) =>
        Effect.gen(function* () {
          const token = yield* tokenFor(athleteId);
          yield* callIntervals(token, "PUT", athletePath(athleteId, "/events/bulk-delete"), {
            body: [{ external_id: externalId }],
          }).pipe(Effect.mapError(calendarError));
          return { withdrawn: true };
        }),
    };
  }),
);
