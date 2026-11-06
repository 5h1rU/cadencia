import * as Schema from "effect/Schema";

/** The shape of an athlete id, for ids that start with one. */
export const ATHLETE_ID_PATTERN = "i[1-9][0-9]*";

/** An athlete, identified by their Intervals.icu athlete id: `i` and digits, such as `i393051`. */
export const AthleteId = Schema.String.pipe(
  Schema.check(Schema.isPattern(new RegExp(`^${ATHLETE_ID_PATTERN}$`))),
  Schema.brand("AthleteId"),
);
export type AthleteId = typeof AthleteId.Type;

/** The athlete an athlete-scoped id (`<athleteId>:…`) belongs to. */
export const ownerOf = (id: string): AthleteId => AthleteId.make(id.slice(0, id.indexOf(":")));

/** The part of an athlete-scoped id after `<athleteId>:`. */
export const keyOf = (id: string): string => id.slice(id.indexOf(":") + 1);
