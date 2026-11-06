import * as Schema from "effect/Schema";
import { type Day, toUtc } from "./Day.ts";

/** A weekday as Intervals and Cadencia number it: 1 = Sunday … 7 = Saturday. */
export const Weekday = Schema.Int.pipe(Schema.check(Schema.isBetween({ minimum: 1, maximum: 7 })), Schema.brand("Weekday"));
export type Weekday = typeof Weekday.Type;

/** The weekday of a day: 1 = Sunday … 7 = Saturday. */
export const weekdayOf = (day: Day): Weekday => Weekday.make(toUtc(day).getUTCDay() + 1);

/** A week of a plan, 1-based from its start. Two years at most. */
export const WeekNumber = Schema.Int.pipe(
  Schema.check(Schema.isBetween({ minimum: 1, maximum: 104 })),
  Schema.brand("WeekNumber"),
);
export type WeekNumber = typeof WeekNumber.Type;
