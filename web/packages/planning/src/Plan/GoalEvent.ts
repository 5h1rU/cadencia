import { Day } from "@cadencia/kernel/Calendar/Day";
import { Paragraph, Title } from "@cadencia/kernel/Text";
import { Kilometers } from "@cadencia/kernel/Training/Units";
import * as Schema from "effect/Schema";

/** The day the plan builds towards. */
export const GoalEvent = Schema.Struct({
  name: Title,
  day: Day,
  distanceKm: Schema.NullOr(Kilometers),
  /** A race is ridden at the limit; a group ride or gran fondo is a priority day, not a race effort. */
  isRace: Schema.Boolean,
  objective: Paragraph,
});
export type GoalEvent = typeof GoalEvent.Type;
