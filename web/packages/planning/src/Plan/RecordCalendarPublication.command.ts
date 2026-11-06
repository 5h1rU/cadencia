import { PlanId } from "@cadencia/kernel/Plan.id";
import * as Domain from "@alchemy.run/domain";
import { ExternalId, SessionId } from "./Session.id.ts";

export class SessionPublished extends Domain.Event("SessionPublished", {
  sessionId: SessionId,
  externalId: ExternalId,
}) {}

/** Record that Intervals now shows a session. Sent by `CalendarPublishing`; it never rejects. */
export class RecordCalendarPublication extends Domain.Command("RecordCalendarPublication", {
  target: PlanId,
  input: { sessionId: SessionId, externalId: ExternalId },
  events: [SessionPublished],
}) {}
