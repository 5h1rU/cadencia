import { PlanId } from "@cadencia/kernel/Plan.id";
import * as Domain from "@alchemy.run/domain";
import { PlannedSession } from "./PlannedSession.ts";
import { ExternalId, SessionId } from "./Session.id.ts";

export class SessionPublished extends Domain.Event("SessionPublished", {
  sessionId: SessionId,
  externalId: ExternalId,
}) {}

/**
 * Record that Intervals now shows a session, as it was published. A session
 * that changed since then is not the one Intervals shows, so it stays
 * unpublished until the change is published too. Sent by `CalendarPublishing`;
 * it never rejects.
 */
export class RecordCalendarPublication extends Domain.Command("RecordCalendarPublication", {
  target: PlanId,
  input: { published: PlannedSession },
  events: [SessionPublished],
}) {}
