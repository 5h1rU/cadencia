import { AthleteId } from "@cadencia/kernel/Athlete.id";
import { Day } from "@cadencia/kernel/Day";
import { NotYours } from "@cadencia/kernel/NotYours.rejection";
import { Session } from "@cadencia/kernel/Session.middleware";
import * as Domain from "@alchemy.run/domain";
import * as Schema from "effect/Schema";
import { PlanId } from "./Plan.id.ts";
import { GoalEvent, GoalKind, Phase, PlannedSession, SessionDraft } from "./PlanShape.ts";

/** The plan already exists. */
export class PlanAlreadyExists extends Domain.Rejection("PlanAlreadyExists", {}, { httpApiStatus: 409 }) {}

/** The draft can't become a plan. */
export class InvalidPlan extends Domain.Rejection("InvalidPlan", { reason: Schema.String }, { httpApiStatus: 422 }) {}

export class PlanCreated extends Domain.Event("PlanCreated", {
  athleteId: AthleteId,
  title: Schema.String,
  goal: GoalKind,
  startDay: Day,
  endDay: Day,
  phases: Schema.Array(Phase),
  longRideWeekday: Schema.Int,
  event: Schema.NullOr(GoalEvent),
  sessions: Schema.Array(PlannedSession),
}) {}

/** Create a plan from an accepted consultation draft. Sent by the Coach. */
export class CreatePlan extends Domain.Command(
  "CreatePlan",
  {
    target: PlanId,
    middleware: [Session],
    input: {
      athleteId: AthleteId,
      title: Schema.String,
      goal: GoalKind,
      startDay: Day,
      endDay: Day,
      phases: Schema.Array(Phase),
      longRideWeekday: Schema.Int,
      event: Schema.NullOr(GoalEvent),
      sessions: Schema.Array(SessionDraft),
    },
    events: [PlanCreated],
    rejects: [PlanAlreadyExists, InvalidPlan, NotYours],
  }
) {}
