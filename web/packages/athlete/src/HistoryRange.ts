import { Day } from "@cadencia/kernel/Calendar/Day";
import * as Schema from "effect/Schema";

/** The days of history to read, `oldest` on or before `newest`. */
export const HistoryRange = Schema.Struct({ oldest: Day, newest: Day }).pipe(
  Schema.check(Schema.makeFilter((r) => (r.oldest <= r.newest ? undefined : "oldest comes on or before newest"))),
);
export type HistoryRange = typeof HistoryRange.Type;
