import * as Schema from "effect/Schema";

/** A calendar day in the athlete's own time zone, as `YYYY-MM-DD`. */
export const Day = Schema.String.pipe(
  Schema.check(Schema.isPattern(/^\d{4}-\d{2}-\d{2}$/)),
  Schema.brand("Day"),
);
export type Day = typeof Day.Type;

const toUtc = (day: Day): Date => new Date(`${day}T00:00:00Z`);
const fromUtc = (date: Date): Day => Day.make(date.toISOString().slice(0, 10));

/** The day `n` days after `day` (before it when `n` is negative). */
export const addDays = (day: Day, n: number): Day => {
  const date = toUtc(day);
  date.setUTCDate(date.getUTCDate() + n);
  return fromUtc(date);
};

/** Whole days from `from` to `to`. */
export const daysBetween = (from: Day, to: Day): number =>
  Math.round((toUtc(to).getTime() - toUtc(from).getTime()) / 86_400_000);

/** The weekday, numbered as Intervals and Cadencia iOS number it: 1 = Sunday … 7 = Saturday. */
export const weekdayOf = (day: Day): number => toUtc(day).getUTCDay() + 1;
