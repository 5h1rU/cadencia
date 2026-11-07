import { AthleteId } from "@cadencia/identity/Athlete.id";
import { NotYours } from "@cadencia/identity/NotYours.rejection";
import { Session } from "@cadencia/identity/Session.middleware";
import { Day } from "@cadencia/kernel/Calendar/Day";
import { Weekday } from "@cadencia/kernel/Calendar/Week";
import { PlanId } from "@cadencia/kernel/Plan.id";
import { Paragraph, Title } from "@cadencia/kernel/Text";
import { GoalKind } from "@cadencia/kernel/Training/Goal";
import { Phase } from "@cadencia/kernel/Training/Phase";
import * as Domain from "@alchemy.run/domain";
import * as Schema from "effect/Schema";
import { GoalEvent } from "./GoalEvent.ts";
import { PlannedSession } from "./PlannedSession.ts";
import { SessionDraft } from "./SessionDraft.ts";

/** The plan already exists. */
export class PlanAlreadyExists extends Domain.Rejection("PlanAlreadyExists", {}, { httpApiStatus: 409 }) {}

/** Why a draft can't become a plan. */
export const InvalidPlanReason = Schema.Literals([
  "endsBeforeStart",
  "twoSessionsOneDay",
  "sessionOutsideDates",
  "noSessions",
  /** Phases must run from week 1 to the plan's last week, one after another. */
  "phasesDontCoverPlan",
  "eventOutsidePlan",
  "eventGoalWithoutEvent",
]);
export type InvalidPlanReason = typeof InvalidPlanReason.Type;

/** The draft can't become a plan. */
export class InvalidPlan extends Domain.Rejection("InvalidPlan", { reason: InvalidPlanReason }, { httpApiStatus: 422 }) {}

export class PlanCreated extends Domain.Event("PlanCreated", {
  athleteId: AthleteId,
  title: Title,
  goal: GoalKind,
  /** What the plan aims for, as agreed with the athlete. */
  objective: Schema.NullOr(Paragraph),
  startDay: Day,
  endDay: Day,
  phases: Schema.Array(Phase),
  longRideWeekday: Weekday,
  event: Schema.NullOr(GoalEvent),
  sessions: Schema.Array(PlannedSession),
}) {}

/** Create a plan from an accepted consultation draft. Sent by the Coach on the athlete's behalf; the plan id names its athlete. */
export class CreatePlan extends Domain.Command("CreatePlan", {
  target: PlanId,
  middleware: [Session],
  input: {
    title: Title,
    goal: GoalKind,
    objective: Schema.NullOr(Paragraph),
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
