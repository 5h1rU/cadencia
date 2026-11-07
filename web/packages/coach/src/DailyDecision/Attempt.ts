import * as Schema from "effect/Schema";

/** The number of an attempt to have the AI's answer accepted, starting at 1. */
export const Attempt = Schema.Int.pipe(Schema.check(Schema.isGreaterThanOrEqualTo(1)), Schema.brand("Attempt"));
export type Attempt = typeof Attempt.Type;
