import { Day } from "@cadencia/kernel/Day";
import { NotYours } from "@cadencia/kernel/NotYours.rejection";
import { Session } from "@cadencia/kernel/Session.middleware";
import * as Domain from "@alchemy.run/domain";
import * as Schema from "effect/Schema";
import { DayOutsidePlan } from "./DayOutsidePlan.rejection.ts";
import { PlanId } from "./Plan.id.ts";
import { PlanNotActive } from "./PlanNotActive.rejection.ts";
import { PlannedSession } from "./PlanShape.ts";
import { SessionNotFound } from "./SessionNotFound.rejection.ts";

/** Another session already takes that day. */
export class DayTaken extends Domain.Rejection("DayTaken", { day: Day }, { httpApiStatus: 409 }) {}

export class SessionMoved extends Domain.Event("SessionMoved", {
  session: PlannedSession,
  fromDay: Day,
}) {}

/** Move a planned session to another day of the plan. */
export class MoveSession extends Domain.Command(
  "MoveSession",
  {
    target: PlanId,
    middleware: [Session],
    input: { sessionId: Schema.String, toDay: Day },
    events: [SessionMoved],
    rejects: [PlanNotActive, SessionNotFound, DayOutsidePlan, DayTaken, NotYours],
  }
) {}
