import * as Domain from "@alchemy.run/domain";
import * as Schema from "effect/Schema";
import { PlanId } from "./Plan.id.ts";

export class SessionChangedInIntervals extends Domain.Event("SessionChangedInIntervals", {
  sessionId: Schema.String,
}) {}

export class SessionRemovedInIntervals extends Domain.Event("SessionRemovedInIntervals", {
  sessionId: Schema.String,
}) {}

/**
 * Record that the athlete changed or removed a published session in Intervals.
 * Intervals wins, so it never rejects. Sent by the Intervals sync.
 */
export class RecordExternalChange extends Domain.Command("RecordExternalChange", {
  target: PlanId,
  input: { externalId: Schema.String, change: Schema.Literals(["changed", "removed"]) },
  events: [SessionChangedInIntervals, SessionRemovedInIntervals],
}) {}
