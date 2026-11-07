import { PlanId } from "@cadencia/kernel/Plan.id";
import * as Domain from "@alchemy.run/domain";
import { CalendarProblem } from "./Calendar.external.ts";
import { SessionId } from "./Session.id.ts";

export class SessionPublicationFailed extends Domain.Event("SessionPublicationFailed", {
  sessionId: SessionId,
  problem: CalendarProblem,
}) {}

/**
 * Record that the calendar refused a session, so the athlete can see it and
 * the plan's other changes still reach Intervals. Sent by `CalendarPublishing`;
 * it never rejects.
 */
export class RecordCalendarFailure extends Domain.Command("RecordCalendarFailure", {
  target: PlanId,
  input: { sessionId: SessionId, problem: CalendarProblem },
  events: [SessionPublicationFailed],
}) {}
