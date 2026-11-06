import { AthleteId } from "@cadencia/kernel/Athlete.id";
import * as Domain from "@alchemy.run/domain";
import * as Schema from "effect/Schema";
import { PlannedSession } from "./PlanShape.ts";

/** The athlete's Intervals.icu calendar, where the plan's sessions are published. */
export class Calendar extends Domain.ExternalSystem("Calendar", {
  publishSession: {
    args: { athleteId: AthleteId, session: PlannedSession },
    success: { eventId: Schema.Number },
  },
  withdrawSession: {
    args: { athleteId: AthleteId, externalId: Schema.String },
    success: { withdrawn: Schema.Boolean },
  },
}) {}
