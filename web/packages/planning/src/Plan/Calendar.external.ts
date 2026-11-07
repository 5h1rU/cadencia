import { AthleteId } from "@cadencia/identity/Athlete.id";
import * as Domain from "@alchemy.run/domain";
import * as Schema from "effect/Schema";
import { PlannedSession } from "./PlanShape.ts";
import { ExternalId } from "./Session.id.ts";

/** Why the calendar refused a session: the athlete isn't connected any more, or the calendar won't take it. */
export const CalendarProblem = Schema.Literals(["notConnected", "refused"]);
export type CalendarProblem = typeof CalendarProblem.Type;

/** The calendar can't be reached right now. Trying again later may work. */
export class CalendarUnavailable extends Schema.TaggedError<CalendarUnavailable>()("CalendarUnavailable", {}) {}

/** The calendar refused the change, and trying again won't help until something changes. */
export class CalendarRefused extends Schema.TaggedError<CalendarRefused>()("CalendarRefused", {
  problem: CalendarProblem,
}) {}

/** The athlete's Intervals.icu calendar, where the plan's sessions are published. */
export class Calendar extends Domain.ExternalSystem("Calendar", {
  publishSession: {
    args: { athleteId: AthleteId, session: PlannedSession },
    success: { published: Schema.Boolean },
    error: [CalendarUnavailable, CalendarRefused],
  },
  withdrawSession: {
    args: { athleteId: AthleteId, externalId: ExternalId },
    success: { withdrawn: Schema.Boolean },
    error: [CalendarUnavailable, CalendarRefused],
  },
}) {}
