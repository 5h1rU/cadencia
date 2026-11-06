import { PlanId } from "@cadencia/kernel/Plan.id";
import * as Schema from "effect/Schema";
import { DayLimit } from "../CoachShape.ts";
import { Headline } from "../CoachText.ts";

/** A change to the plan the coach understood from a message. It takes effect only once the athlete accepts it. */
export const Intent = Schema.Struct({
  planId: PlanId,
  summary: Headline,
  limits: Schema.Array(DayLimit).pipe(Schema.check(Schema.isNonEmpty())),
});
export type Intent = typeof Intent.Type;

export const IntentStatus = Schema.Literals(["proposed", "accepted", "dismissed", "applied", "refused"]);
export type IntentStatus = typeof IntentStatus.Type;
