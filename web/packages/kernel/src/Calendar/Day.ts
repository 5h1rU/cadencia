import * as Schema from "effect/Schema";

const isCalendarDay = (text: string): boolean => {
  const date = new Date(`${text}T00:00:00Z`);
  return !Number.isNaN(date.getTime()) && date.toISOString().slice(0, 10) === text;
};

/** A calendar day that exists, in the athlete's own time zone, as `YYYY-MM-DD`. */
export const Day = Schema.String.pipe(
  Schema.check(
    Schema.isPattern(/^\d{4}-\d{2}-\d{2}$/),
    Schema.makeFilter((text: string) => (isCalendarDay(text) ? undefined : "a calendar day that exists")),
  ),
  Schema.brand("Day"),
);
export type Day = typeof Day.Type;

/** Midnight UTC of a day, for arithmetic. */
export const toUtc = (day: Day): Date => new Date(`${day}T00:00:00Z`);
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
