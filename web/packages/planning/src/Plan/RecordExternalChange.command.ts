import { Authenticated } from "@cadencia/identity/Authenticated.middleware";
import { NotYours } from "@cadencia/identity/NotYours.rejection";
import { PlanId } from "@cadencia/kernel/Plan.id";
import * as Domain from "@alchemy.run/domain";
import * as Schema from "effect/Schema";
import { PlannedSession } from "./PlannedSession.ts";
import { ExternalId, SessionId } from "./Session.id.ts";

export class SessionChangedInIntervals extends Domain.Event("SessionChangedInIntervals", {
  sessionId: SessionId,
}) {}

export class SessionRemovedInIntervals extends Domain.Event("SessionRemovedInIntervals", {
  sessionId: SessionId,
}) {}

/**
 * Record that the athlete changed or removed a published session in Intervals.
 * Intervals wins. Only the Intervals sync sends it, with the session as the
 * sync compared it: an observation of a session that has changed since (moved
 * and published again) is stale, and only a session that is published as
 * Cadencia last wrote it can be taken over.
 */
export class RecordExternalChange extends Domain.Command("RecordExternalChange", {
  target: PlanId,
  middleware: [Authenticated],
  input: { externalId: ExternalId, change: Schema.Literals(["changed", "removed"]), observed: PlannedSession },
  events: [SessionChangedInIntervals, SessionRemovedInIntervals],
  rejects: [NotYours],
}) {}
