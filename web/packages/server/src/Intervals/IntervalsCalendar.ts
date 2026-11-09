import { totalSeconds } from "@cadencia/kernel/Training/Workout";
import { Calendar, CalendarRefused, CalendarUnavailable } from "@cadencia/planning/Plan/Calendar.external";
import type { PlannedSession } from "@cadencia/planning/Plan/PlannedSession";
import type { RuntimeContext } from "alchemy/RuntimeContext";
import * as Effect from "effect/Effect";
import * as Option from "effect/Option";
import * as Schema from "effect/Schema";
import { Connections } from "../Connections.ts";
import {
  athletePath,
  callIntervals,
  type IntervalsError,
  IntervalsEventId,
  kindOf,
  reportIntervalsFailure,
} from "./IntervalsHttp.ts";
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

/** What Intervals answers to a bulk upsert of one entry: the event it wrote. */
const Upserted = Schema.Tuple([Schema.Struct({ id: IntervalsEventId })]);

/** Intervals' answer in the calendar's terms. */
const calendarError = (error: IntervalsError): CalendarUnavailable | CalendarRefused => {
  const kind = kindOf(error);
  return kind === "unavailable" ? new CalendarUnavailable() : new CalendarRefused({ problem: kind });
};

/**
 * The Calendar external system over Intervals.icu. Upserts by `external_id`
 * (with OAuth, Intervals updates this app's event with the same id instead of
 * duplicating it) and deletes by `external_id`. An athlete who disconnected
 * Intervals has no token any more: the calendar refuses them as not connected.
 *
 * The policy records a refusal as an event and retries an outage, so neither
 * fails the Worker: every call Intervals fails is reported here, for
 * Cloudflare to group.
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
          }).pipe(Effect.tapError(reportIntervalsFailure("publishSession", athleteId)), Effect.mapError(calendarError));
          // A success that doesn't name the event written confirms nothing: it is retried like an outage.
          if (Option.isNone(Schema.decodeUnknownOption(Upserted)(result))) return yield* new CalendarUnavailable();
          return { published: true };
        }),
      withdrawSession: ({ athleteId, externalId }) =>
        Effect.gen(function* () {
          const token = yield* tokenFor(athleteId);
          yield* callIntervals(token, "PUT", athletePath(athleteId, "/events/bulk-delete"), {
            body: [{ external_id: externalId }],
          }).pipe(Effect.tapError(reportIntervalsFailure("withdrawSession", athleteId)), Effect.mapError(calendarError));
          return { withdrawn: true };
        }),
    };
  }),
);
