import { AthleteId } from "@cadencia/identity/Athlete.id";
import { NotYours } from "@cadencia/identity/NotYours.rejection";
import { Session } from "@cadencia/identity/Session.middleware";
import { Day } from "@cadencia/kernel/Calendar/Day";
import { Weekday } from "@cadencia/kernel/Calendar/Week";
import { PlanId } from "@cadencia/kernel/Plan.id";
import { Title } from "@cadencia/kernel/Text";
import * as Domain from "@alchemy.run/domain";
import * as Schema from "effect/Schema";
import { GoalEvent, GoalKind, Phase, PlannedSession, SessionDraft } from "./PlanShape.ts";

/** The plan already exists. */
export class PlanAlreadyExists extends Domain.Rejection("PlanAlreadyExists", {}, { httpApiStatus: 409 }) {}

/** Why a draft can't become a plan. */
export const InvalidPlanReason = Schema.Literals([
  "planOfAnotherAthlete",
  "endsBeforeStart",
  "twoSessionsOneDay",
  "sessionOutsideDates",
  "noSessions",
]);
export type InvalidPlanReason = typeof InvalidPlanReason.Type;

/** The draft can't become a plan. */
export class InvalidPlan extends Domain.Rejection("InvalidPlan", { reason: InvalidPlanReason }, { httpApiStatus: 422 }) {}

export class PlanCreated extends Domain.Event("PlanCreated", {
  athleteId: AthleteId,
  title: Title,
  goal: GoalKind,
  startDay: Day,
  endDay: Day,
  phases: Schema.Array(Phase),
  longRideWeekday: Weekday,
  event: Schema.NullOr(GoalEvent),
  sessions: Schema.Array(PlannedSession),
}) {}

/** Create a plan from an accepted consultation draft. Sent by the Coach. */
export class CreatePlan extends Domain.Command("CreatePlan", {
  target: PlanId,
  middleware: [Session],
  input: {
    athleteId: AthleteId,
    title: Title,
    goal: GoalKind,
    startDay: Day,
    endDay: Day,
    phases: Schema.Array(Phase),
    longRideWeekday: Weekday,
    event: Schema.NullOr(GoalEvent),
    sessions: Schema.Array(SessionDraft),
  },
  events: [PlanCreated],
  rejects: [PlanAlreadyExists, InvalidPlan, NotYours],
}) {}
