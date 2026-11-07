import { Paragraph } from "@cadencia/kernel/Text";
import * as Schema from "effect/Schema";
import { Headline } from "./Headline.ts";

/** The coach's note for a day, in the athlete's words. */
export const CoachNote = Schema.Struct({
  headline: Headline,
  body: Paragraph,
  session: Paragraph,
  watch: Schema.NullOr(Paragraph),
});
export type CoachNote = typeof CoachNote.Type;
