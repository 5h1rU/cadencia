import * as Schema from "effect/Schema";
import { WeekNumber } from "../Calendar/Week.ts";
import { Paragraph } from "../Text.ts";

/** The focus of a block of weeks. */
export const PhaseFocus = Schema.Literals(["prepare", "base", "build", "peak", "taper", "consolidate", "recover"]);
export type PhaseFocus = typeof PhaseFocus.Type;

/** A block of weeks with one focus. */
export const Phase = Schema.Struct({
  focus: PhaseFocus,
  startWeek: WeekNumber,
  endWeek: WeekNumber,
  summary: Paragraph,
}).pipe(Schema.check(Schema.makeFilter((p) => (p.startWeek <= p.endWeek ? undefined : "a phase ends on or after its start week"))));
export type Phase = typeof Phase.Type;
