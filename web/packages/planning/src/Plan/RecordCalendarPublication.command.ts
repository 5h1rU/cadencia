import * as Domain from "@alchemy.run/domain";
import * as Schema from "effect/Schema";
import { PlanId } from "./Plan.id.ts";

export class SessionPublished extends Domain.Event("SessionPublished", {
  sessionId: Schema.String,
  externalId: Schema.String,
}) {}

/** Record that Intervals now shows a session. Sent by `CalendarPublishing`; it never rejects. */
export class RecordCalendarPublication extends Domain.Command("RecordCalendarPublication", {
  target: PlanId,
  input: { sessionId: Schema.String, externalId: Schema.String },
  events: [SessionPublished],
}) {}
