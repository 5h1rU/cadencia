import { Paragraph } from "@cadencia/kernel/Text";
import * as Schema from "effect/Schema";

/** Why the plan refused a proposal, in the coach's words. */
export const RefusalReason = Schema.Literals([
  "planNotActive",
  "dayNotPlanned",
  "availabilityExceeded",
  "intensityAfterHardTraining",
  "hardensPlan",
  "purposeMismatch",
  "invalidPlan",
  "planAlreadyExists",
  "implausibleToday",
  "notYours",
]);
export type RefusalReason = typeof RefusalReason.Type;

/** A refusal and the plan's evidence for it, for the AI to try again and for the athlete to read. */
export const Refusal = Schema.Struct({ reason: RefusalReason, detail: Schema.NullOr(Paragraph) });
export type Refusal = typeof Refusal.Type;
