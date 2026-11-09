import type { AthleteId } from "@cadencia/identity/Athlete.id";
import * as Console from "effect/Console";
import * as Duration from "effect/Duration";
import * as Effect from "effect/Effect";
import * as Redacted from "effect/Redacted";
import * as Schema from "effect/Schema";

export const INTERVALS = "https://intervals.icu";

/**
 * How long any one call to Intervals.icu may take, its answer's body included.
 * Intervals answers in a second or two; a call still open after this is
 * aborted and counts as Intervals not answering, so whatever waits on it (the
 * athlete's request, the webhook's acknowledgement, a policy) ends as the
 * outage it already knows instead of hanging for as long as the Worker lives.
 */
export const INTERVALS_DEADLINE = Duration.seconds(10);

/** An event of the Intervals.icu calendar. Planning names sessions by their external id; only this adapter sees these. */
export const IntervalsEventId = Schema.Int.pipe(Schema.check(Schema.isGreaterThanOrEqualTo(1)), Schema.brand("IntervalsEventId"));
export type IntervalsEventId = typeof IntervalsEventId.Type;

/** An HTTP status code; 0 when Intervals could not be reached at all, or didn't answer within the deadline. */
export const HttpStatus = Schema.Int.pipe(Schema.check(Schema.isBetween({ minimum: 0, maximum: 599 })), Schema.brand("HttpStatus"));
export type HttpStatus = typeof HttpStatus.Type;

/** Intervals.icu answered with an error, or could not be reached. */
export class IntervalsError extends Schema.TaggedError<IntervalsError>()("IntervalsError", {
  status: HttpStatus,
  message: Schema.String,
}) {}

/**
 * What an Intervals error means for whoever called: `unavailable` (no answer,
 * a rate limit or an outage) may pass by trying again; `notConnected` (a
 * revoked or missing authorization) needs the athlete to connect again; any
 * other refusal won't change by trying again.
 */
export const kindOf = (error: IntervalsError): "unavailable" | "notConnected" | "refused" =>
  error.status === 0 || error.status === 429 || error.status >= 500
    ? "unavailable"
    : error.status === 401 || error.status === 403
      ? "notConnected"
      : "refused";

/**
 * One call to the Intervals.icu API as the athlete, with their OAuth token.
 * One that outlasts `INTERVALS_DEADLINE` is aborted and fails like one that
 * never reached Intervals (status 0, `unavailable`).
 */
export const callIntervals = (
  token: Redacted.Redacted<string>,
  method: "GET" | "POST" | "PUT" | "DELETE",
  path: string,
  options: { readonly query?: Record<string, string>; readonly body?: unknown } = {},
) =>
  Effect.tryPromise({
    // The fiber's signal: the deadline below interrupts the call, which aborts the request.
    try: async (signal) => {
      const url = new URL(path, INTERVALS);
      for (const [k, v] of Object.entries(options.query ?? {})) url.searchParams.set(k, v);
      const response = await fetch(url, {
        method,
        headers: {
          authorization: `Bearer ${Redacted.value(token)}`,
          accept: "application/json",
          ...(options.body === undefined ? {} : { "content-type": "application/json" }),
        },
        body: options.body === undefined ? undefined : JSON.stringify(options.body),
        signal,
      });
      const text = await response.text();
      if (!response.ok) throw new IntervalsError({ status: HttpStatus.make(response.status), message: text.slice(0, 500) });
      return text.length === 0 ? null : (JSON.parse(text) as unknown);
    },
    catch: (error) =>
      error instanceof IntervalsError ? error : new IntervalsError({ status: HttpStatus.make(0), message: String(error) }),
  }).pipe(
    Effect.timeoutOrElse({
      duration: INTERVALS_DEADLINE,
      orElse: () => Effect.fail(new IntervalsError({ status: HttpStatus.make(0), message: "No answer within the deadline" })),
    }),
  );

/**
 * Report a failed Intervals call where Cloudflare groups recurring failures:
 * Workers Issues reads logs written with `console.error`, which the logger
 * Alchemy gives a Worker (`Logger.consolePretty`) doesn't use for a message,
 * whatever its level. A refusal recorded as an event, or let go, would
 * otherwise leave no trace there.
 *
 * Only the operation, the athlete's id, the status and what it means are
 * written: never Intervals' message, which can quote what the athlete wrote.
 */
export const reportIntervalsFailure = (operation: string, athleteId: AthleteId) => (error: IntervalsError) =>
  Console.error({ message: "Intervals call failed", operation, athleteId, status: error.status, kind: kindOf(error) });

/**
 * A calendar event as Intervals returns it: only the fields Cadencia reads,
 * decoded at the edge, the rest dropped. Its other fields stay in Intervals'
 * own shape because any app, or the athlete, may have written them.
 */
export const IntervalsEvent = Schema.Struct({
  id: IntervalsEventId,
  external_id: Schema.optional(Schema.NullOr(Schema.String)),
  start_date_local: Schema.optional(Schema.NullOr(Schema.String)),
  name: Schema.optional(Schema.NullOr(Schema.String)),
  moving_time: Schema.optional(Schema.NullOr(Schema.Number)),
  description: Schema.optional(Schema.NullOr(Schema.String)),
});
export type IntervalsEvent = typeof IntervalsEvent.Type;

export const athletePath = (athleteId: AthleteId, rest: string) => `/api/v1/athlete/${athleteId}${rest}`;
