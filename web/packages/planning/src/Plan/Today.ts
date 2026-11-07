import { addDays, Day } from "@cadencia/kernel/Calendar/Day";
import * as DateTime from "effect/DateTime";

/** The UTC date of an instant: the day for actors that have no local day, such as policies. */
export const utcDayOf = (now: DateTime.Utc): Day => Day.make(DateTime.formatIsoDate(now));

/** Whether `today` can be someone's local day at `now`: the UTC date, give or take one day. */
export const isPlausibleToday = (today: Day, now: DateTime.Utc): boolean => {
  const utc = utcDayOf(now);
  return today >= addDays(utc, -1) && today <= addDays(utc, 1);
};
