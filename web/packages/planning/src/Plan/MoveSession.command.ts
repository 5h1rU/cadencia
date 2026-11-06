import { NotYours } from "@cadencia/identity/NotYours.rejection";
import { Session } from "@cadencia/identity/Session.middleware";
import { Day } from "@cadencia/kernel/Calendar/Day";
import { PlanId } from "@cadencia/kernel/Plan.id";
import * as Domain from "@alchemy.run/domain";
import { DayOutsidePlan } from "./DayOutsidePlan.rejection.ts";
import { PlanNotActive } from "./PlanNotActive.rejection.ts";
import { PlannedSession } from "./PlanShape.ts";
import { SessionId } from "./Session.id.ts";
import { SessionNotFound } from "./SessionNotFound.rejection.ts";

/** Another session already takes that day. */
export class DayTaken extends Domain.Rejection("DayTaken", { day: Day }, { httpApiStatus: 409 }) {}

export class SessionMoved extends Domain.Event("SessionMoved", {
  session: PlannedSession,
  fromDay: Day,
}) {}

/** Move a planned session to another day of the plan. */
export class MoveSession extends Domain.Command("MoveSession", {
  target: PlanId,
  middleware: [Session],
  input: { sessionId: SessionId, toDay: Day },
  events: [SessionMoved],
  rejects: [PlanNotActive, SessionNotFound, DayOutsidePlan, DayTaken, NotYours],
}) {}
