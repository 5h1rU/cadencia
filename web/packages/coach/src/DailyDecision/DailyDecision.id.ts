import { ATHLETE_ID_PATTERN, type AthleteId, keyOf } from "@cadencia/identity/Athlete.id";
import { Day } from "@cadencia/kernel/Calendar/Day";
import * as Schema from "effect/Schema";

/** One athlete's decision for one day: `<athleteId>:<YYYY-MM-DD>`, on a day that exists. */
export const DailyDecisionId = Schema.String.pipe(
  Schema.check(
    Schema.isPattern(new RegExp(`^${ATHLETE_ID_PATTERN}:\\d{4}-\\d{2}-\\d{2}$`)),
    Schema.makeFilter((id: string) => (Schema.is(Day)(keyOf(id)) ? undefined : "a calendar day that exists")),
  ),
  Schema.brand("DailyDecisionId"),
);
export type DailyDecisionId = typeof DailyDecisionId.Type;

export const dailyDecisionIdFor = (athleteId: AthleteId, day: Day): DailyDecisionId =>
  DailyDecisionId.make(`${athleteId}:${day}`);

export const dayOfDecision = (id: DailyDecisionId): Day => Day.make(keyOf(id));
