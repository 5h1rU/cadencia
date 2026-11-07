import { AthleteId } from "@cadencia/identity/Athlete.id";
import * as HttpApiEndpoint from "effect/http-api/HttpApiEndpoint";
import * as HttpApiGroup from "effect/http-api/HttpApiGroup";
import * as OpenApi from "effect/http-api/OpenApi";
import * as Option from "effect/Option";
import * as Redacted from "effect/Redacted";
import * as Schema from "effect/Schema";

/**
 * One event of an Intervals.icu webhook, as Intervals sends it: the athlete it
 * is about and what happened. Each type carries more (`events`,
 * `deleted_events`, an `activity`…); Cadencia reads Intervals again rather
 * than trusting them, as deliveries can repeat or arrive after a later change.
 */
export const IntervalsWebhookEvent = Schema.Struct({
  athlete_id: Schema.Union([Schema.String, Schema.Number]),
  type: Schema.String,
});
export type IntervalsWebhookEvent = typeof IntervalsWebhookEvent.Type;

/** A webhook delivery: the secret configured for the app in Intervals, and the events. */
export const IntervalsWebhook = Schema.Struct({
  secret: Schema.RedactedFromValue(Schema.String),
  events: Schema.Array(IntervalsWebhookEvent),
}).annotate({ title: "IntervalsWebhook", description: "A webhook delivery from Intervals.icu." });

/** The delivery doesn't carry the app's webhook secret. */
export class WebhookRefused extends Schema.TaggedError<WebhookRefused>()(
  "WebhookRefused",
  {},
  { httpApiStatus: 401, description: "The webhook secret doesn't match." },
) {}

/** Intervals.icu tells Cadencia what athletes changed there; Cadencia then reads it again. */
export const IntervalsWebhookGroup = HttpApiGroup.make("intervalsWebhook")
  .add(
    HttpApiEndpoint.post("receive", "/intervals", {
      payload: IntervalsWebhook,
      success: Schema.Struct({ received: Schema.Int }).annotate({ description: "How many events were read." }),
      error: WebhookRefused,
    }).annotate(OpenApi.Description, "Receive Intervals.icu webhooks (CALENDAR_UPDATED)."),
  )
  .prefix("/webhooks")
  .annotate(OpenApi.Description, "Webhooks from Intervals.icu.");

/** Intervals names athletes `i123`, and some payloads carry only the number. */
export const athleteOfWebhook = (event: IntervalsWebhookEvent): Option.Option<AthleteId> => {
  const id = String(event.athlete_id);
  return Schema.decodeUnknownOption(AthleteId)(/^\d+$/.test(id) ? `i${id}` : id);
};

/** The athletes whose calendar changed in Intervals, once each. */
export const calendarsChanged = (events: ReadonlyArray<IntervalsWebhookEvent>): ReadonlyArray<AthleteId> => [
  ...new Set(events.filter((e) => e.type === "CALENDAR_UPDATED").flatMap((e) => Option.toArray(athleteOfWebhook(e)))),
];

/** Compare secrets in time that doesn't depend on where they differ. */
export const sameSecret = (received: Redacted.Redacted<string>, expected: Redacted.Redacted<string>): boolean => {
  const a = new TextEncoder().encode(Redacted.value(received));
  const b = new TextEncoder().encode(Redacted.value(expected));
  let difference = a.length ^ b.length;
  for (let i = 0; i < Math.max(a.length, b.length); i++) difference |= (a[i] ?? 0) ^ (b[i] ?? 0);
  return difference === 0;
};
