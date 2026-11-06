import * as Schema from "effect/Schema";
import { DayLimit } from "../CoachShape.ts";

/** A change to the plan the coach understood from a message. It takes effect only once the athlete accepts it. */
export const Intent = Schema.Struct({
  planId: Schema.String,
  summary: Schema.String,
  limits: Schema.Array(DayLimit),
});
export type Intent = typeof Intent.Type;

export const IntentStatus = Schema.Literals(["proposed", "accepted", "dismissed", "applied", "refused"]);
export type IntentStatus = typeof IntentStatus.Type;
