import { AthleteId } from "@cadencia/identity/Athlete.id";
import * as Domain from "@alchemy.run/domain";
import * as Schema from "effect/Schema";
import { PlannedSession } from "./PlanShape.ts";
import { ExternalId, IntervalsEventId } from "./Session.id.ts";

/** The athlete's Intervals.icu calendar, where the plan's sessions are published. */
export class Calendar extends Domain.ExternalSystem("Calendar", {
  publishSession: {
    args: { athleteId: AthleteId, session: PlannedSession },
    /** The calendar event, when Intervals says which one it is. */
    success: { eventId: Schema.NullOr(IntervalsEventId) },
  },
  withdrawSession: {
    args: { athleteId: AthleteId, externalId: ExternalId },
    success: { withdrawn: Schema.Boolean },
  },
}) {}
