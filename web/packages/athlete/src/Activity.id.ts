import * as Schema from "effect/Schema";

/** An activity in Intervals.icu, such as `i12345678`. */
export const IntervalsActivityId = Schema.String.pipe(
  Schema.check(Schema.isPattern(/^[A-Za-z0-9_-]{1,64}$/)),
  Schema.brand("IntervalsActivityId"),
);
export type IntervalsActivityId = typeof IntervalsActivityId.Type;
