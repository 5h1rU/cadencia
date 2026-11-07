import { Paragraph } from "@cadencia/kernel/Text";
import * as Schema from "effect/Schema";
import { Headline, ModelName } from "./CoachText.ts";

export { DayLimit } from "@cadencia/kernel/Training/DayLimit";

/** Which device or service ran the AI that produced an interpretation. */
export const InterpretedOn = Schema.Literals(["ios"]);
export type InterpretedOn = typeof InterpretedOn.Type;

/** Where an interpretation came from: the model and the place it ran. */
export const Provenance = Schema.Struct({ model: ModelName, interpretedOn: InterpretedOn });
export type Provenance = typeof Provenance.Type;

/** The coach's note for a day, in the athlete's words. */
export const CoachNote = Schema.Struct({
  headline: Headline,
  body: Paragraph,
  session: Paragraph,
  watch: Schema.NullOr(Paragraph),
});
export type CoachNote = typeof CoachNote.Type;

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

/** What the Planning model said about a proposal. */
export const PlanAnswer = Schema.Union([
  Schema.TaggedStruct("Accepted", {}),
  Schema.TaggedStruct("Refused", { refusal: Refusal }),
]);
export type PlanAnswer = typeof PlanAnswer.Type;
