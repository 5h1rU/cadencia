import * as Schema from "effect/Schema";

/** One athlete's decision for one day: `<athleteId>:<YYYY-MM-DD>`. */
export const DailyDecisionId = Schema.String.pipe(
  Schema.check(Schema.isPattern(/^[^:]+:\d{4}-\d{2}-\d{2}$/)),
  Schema.brand("DailyDecisionId"),
);
export type DailyDecisionId = typeof DailyDecisionId.Type;

export const dayOfDecision = (id: string): string => id.slice(id.indexOf(":") + 1);
