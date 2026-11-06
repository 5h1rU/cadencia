import { Day } from "@cadencia/kernel/Day";
import * as Schema from "effect/Schema";

/** Which device or service ran the AI that produced an interpretation. */
export const InterpretedOn = Schema.Literals(["ios"]);
export type InterpretedOn = typeof InterpretedOn.Type;

/** Where an interpretation came from: the model and the place it ran. */
export const Provenance = Schema.Struct({
  model: Schema.String,
  interpretedOn: InterpretedOn,
});
export type Provenance = typeof Provenance.Type;

/** The coach's note for a day, in the athlete's words. Matches `CoachNote` in Cadencia iOS. */
export const CoachNote = Schema.Struct({
  headline: Schema.String,
  body: Schema.String,
  session: Schema.String,
  watch: Schema.NullOr(Schema.String),
});
export type CoachNote = typeof CoachNote.Type;

/** A limit on one day, as the coach understood it from the athlete. It can only remove riding. */
export const DayLimit = Schema.Struct({
  day: Day,
  maxMinutes: Schema.NullOr(Schema.Int),
  unavailable: Schema.Boolean,
});
export type DayLimit = typeof DayLimit.Type;

/** What the Planning model said about a proposal. */
export const PlanAnswer = Schema.Struct({
  accepted: Schema.Boolean,
  /** The rejection's tag and its evidence, in plain words, when refused. */
  reason: Schema.NullOr(Schema.String),
});
export type PlanAnswer = typeof PlanAnswer.Type;
