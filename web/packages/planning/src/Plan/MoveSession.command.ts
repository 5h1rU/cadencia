import { Authenticated } from "@cadencia/identity/Authenticated.middleware";
import { NotYours } from "@cadencia/identity/NotYours.rejection";
import { Day } from "@cadencia/kernel/Calendar/Day";
import { PlanId } from "@cadencia/kernel/Plan.id";
import * as Domain from "@alchemy.run/domain";
import { DayOutsidePlan } from "./DayOutsidePlan.rejection.ts";
import { PlannedSession, SessionStatus } from "./PlannedSession.ts";
import { PlanNotActive } from "./PlanNotActive.rejection.ts";
import { SessionId } from "./Session.id.ts";

/** No session with that id in the plan. */
export class SessionNotFound extends Domain.Rejection("SessionNotFound", { sessionId: SessionId }, { httpApiStatus: 404 }) {}

/** Another session already takes that day. */
export class DayTaken extends Domain.Rejection("DayTaken", { day: Day }, { httpApiStatus: 409 }) {}

/**
 * The session can't move: the athlete took it over in Intervals, which wins,
 * or it was skipped for an unavailable day.
 */
export class SessionNotMovable extends Domain.Rejection(
  "SessionNotMovable",
  { sessionId: SessionId, status: SessionStatus },
  { httpApiStatus: 409 },
) {}

export class SessionMoved extends Domain.Event("SessionMoved", {
  session: PlannedSession,
  fromDay: Day,
}) {}

/** Move a planned session to another day of the plan. */
export class MoveSession extends Domain.Command("MoveSession", {
  target: PlanId,
  middleware: [Authenticated],
  input: { sessionId: SessionId, toDay: Day },
  events: [SessionMoved],
  rejects: [PlanNotActive, SessionNotFound, SessionNotMovable, DayOutsidePlan, DayTaken, NotYours],
}) {}
