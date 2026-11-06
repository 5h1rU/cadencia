import * as Schema from "effect/Schema";
import { Day } from "../Calendar/Day.ts";
import { Minutes } from "./Units.ts";

/** A limit on one day's riding. It can only remove riding, never add it. */
export const DayLimit = Schema.Struct({
  day: Day,
  maxMinutes: Schema.NullOr(Minutes),
  unavailable: Schema.Boolean,
});
export type DayLimit = typeof DayLimit.Type;
