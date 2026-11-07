import { Day } from "@cadencia/kernel/Calendar/Day";
import { Paragraph } from "@cadencia/kernel/Text";
import { Minutes } from "@cadencia/kernel/Training/Units";
import * as Schema from "effect/Schema";

/** An athlete-authored requirement for one day ("Thursday, 45 minutes at most"). */
export const DayRequirement = Schema.Struct({
  day: Day,
  instructions: Paragraph,
  maxMinutes: Schema.NullOr(Minutes),
});
export type DayRequirement = typeof DayRequirement.Type;
