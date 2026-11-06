import * as Schema from "effect/Schema";

/** How many of something there are. */
export const Count = Schema.Int.pipe(Schema.check(Schema.isGreaterThanOrEqualTo(0)), Schema.brand("Count"));
export type Count = typeof Count.Type;

/** The number of an attempt to have the AI's answer accepted, starting at 1. */
export const Attempt = Schema.Int.pipe(Schema.check(Schema.isGreaterThanOrEqualTo(1)), Schema.brand("Attempt"));
export type Attempt = typeof Attempt.Type;
