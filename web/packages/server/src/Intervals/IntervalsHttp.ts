import type { AthleteId } from "@cadencia/identity/Athlete.id";
import * as Effect from "effect/Effect";
import * as Redacted from "effect/Redacted";
import * as Schema from "effect/Schema";

export const INTERVALS = "https://intervals.icu";

/** An event of the Intervals.icu calendar. Planning names sessions by their external id; only this adapter sees these. */
export const IntervalsEventId = Schema.Int.pipe(Schema.check(Schema.isGreaterThanOrEqualTo(1)), Schema.brand("IntervalsEventId"));
export type IntervalsEventId = typeof IntervalsEventId.Type;

/** An HTTP status code; 0 when Intervals could not be reached at all. */
export const HttpStatus = Schema.Int.pipe(Schema.check(Schema.isBetween({ minimum: 0, maximum: 599 })), Schema.brand("HttpStatus"));
export type HttpStatus = typeof HttpStatus.Type;

/** Intervals.icu answered with an error, or could not be reached. */
export class IntervalsError extends Schema.TaggedError<IntervalsError>()("IntervalsError", {
  status: HttpStatus,
  message: Schema.String,
}) {}

/** One call to the Intervals.icu API as the athlete, with their OAuth token. */
export const callIntervals = (
  token: Redacted.Redacted<string>,
  method: "GET" | "POST" | "PUT" | "DELETE",
  path: string,
  options: { readonly query?: Record<string, string>; readonly body?: unknown } = {},
) =>
  Effect.tryPromise({
    try: async () => {
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
      });
      const text = await response.text();
      if (!response.ok) throw new IntervalsError({ status: HttpStatus.make(response.status), message: text.slice(0, 500) });
      return text.length === 0 ? null : (JSON.parse(text) as unknown);
    },
    catch: (error) =>
      error instanceof IntervalsError ? error : new IntervalsError({ status: HttpStatus.make(0), message: String(error) }),
  });

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
});
export type IntervalsEvent = typeof IntervalsEvent.Type;

export const athletePath = (athleteId: AthleteId, rest: string) => `/api/v1/athlete/${athleteId}${rest}`;
