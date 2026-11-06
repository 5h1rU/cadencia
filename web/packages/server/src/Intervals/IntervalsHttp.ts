import type { AthleteId } from "@cadencia/kernel/Athlete.id";
import * as Effect from "effect/Effect";
import * as Redacted from "effect/Redacted";
import * as Schema from "effect/Schema";

export const INTERVALS = "https://intervals.icu";

/** Intervals.icu answered with an error, or could not be reached. */
export class IntervalsError extends Schema.TaggedError<IntervalsError>()("IntervalsError", {
  status: Schema.Number,
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
      if (!response.ok) throw new IntervalsError({ status: response.status, message: text.slice(0, 500) });
      return text.length === 0 ? null : (JSON.parse(text) as unknown);
    },
    catch: (error) =>
      error instanceof IntervalsError ? error : new IntervalsError({ status: 0, message: String(error) }),
  });

/** A calendar event as Intervals returns it; only the fields Cadencia reads. */
export interface IntervalsEvent {
  readonly id: number;
  readonly external_id?: string | null;
  readonly start_date_local?: string | null;
  readonly name?: string | null;
  readonly moving_time?: number | null;
  readonly description?: string | null;
}

export const athletePath = (athleteId: AthleteId, rest: string) => `/api/v1/athlete/${athleteId}${rest}`;
