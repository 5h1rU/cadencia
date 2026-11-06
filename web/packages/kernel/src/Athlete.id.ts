import * as Schema from "effect/Schema";

/** An athlete, identified by their Intervals.icu athlete id (for example `i12345`). */
export const AthleteId = Schema.String.pipe(Schema.brand("AthleteId"));
export type AthleteId = typeof AthleteId.Type;
