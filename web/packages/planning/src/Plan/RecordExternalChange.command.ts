import { NotYours } from "@cadencia/identity/NotYours.rejection";
import { Session } from "@cadencia/identity/Session.middleware";
import { PlanId } from "@cadencia/kernel/Plan.id";
import * as Domain from "@alchemy.run/domain";
import * as Schema from "effect/Schema";
import { ExternalId, SessionId } from "./Session.id.ts";

export class SessionChangedInIntervals extends Domain.Event("SessionChangedInIntervals", {
  sessionId: SessionId,
}) {}

export class SessionRemovedInIntervals extends Domain.Event("SessionRemovedInIntervals", {
  sessionId: SessionId,
}) {}

/**
 * Record that the athlete changed or removed a published session in Intervals.
 * Intervals wins. Only the Intervals sync sends it, and only a session that is
 * published as Cadencia last wrote it can be taken over.
 */
export class RecordExternalChange extends Domain.Command("RecordExternalChange", {
  target: PlanId,
  middleware: [Session],
  input: { externalId: ExternalId, change: Schema.Literals(["changed", "removed"]) },
  events: [SessionChangedInIntervals, SessionRemovedInIntervals],
  rejects: [NotYours],
}) {}
