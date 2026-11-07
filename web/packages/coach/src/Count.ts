import * as Schema from "effect/Schema";

/** How many of something there are. */
export const Count = Schema.Int.pipe(Schema.check(Schema.isGreaterThanOrEqualTo(0)), Schema.brand("Count"));
export type Count = typeof Count.Type;
