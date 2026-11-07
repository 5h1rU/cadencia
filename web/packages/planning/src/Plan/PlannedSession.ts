import { Day } from "@cadencia/kernel/Calendar/Day";
import { Paragraph, Title } from "@cadencia/kernel/Text";
import { SessionKind } from "@cadencia/kernel/Training/SessionKind";
import { Minutes } from "@cadencia/kernel/Training/Units";
import { Workout } from "@cadencia/kernel/Training/Workout";
import * as Schema from "effect/Schema";
import { ExternalId, SessionId } from "./Session.id.ts";

/**
 * Where a planned session stands. `provisional` is intent only; `concrete`
 * has a workout; `published` is in the Intervals calendar; the last two mean
 * the athlete changed or removed it in Intervals, which wins.
 */
export const SessionStatus = Schema.Literals([
  "provisional",
  "concrete",
  "published",
  "skipped",
  "changedInIntervals",
  "removedInIntervals",
]);
export type SessionStatus = typeof SessionStatus.Type;

/** One session of the plan, as intent and, once concrete, as a workout. */
export const PlannedSession = Schema.Struct({
  sessionId: SessionId,
  day: Day,
  kind: SessionKind,
  title: Title,
  targetMinutes: Minutes,
  purpose: Paragraph,
  status: SessionStatus,
  workout: Schema.NullOr(Workout),
  /** The Intervals `external_id` this session is published under. */
  externalId: ExternalId,
});
export type PlannedSession = typeof PlannedSession.Type;

/** Sessions the athlete has taken over in Intervals stay as they are: Intervals wins. */
export const isOwnedByCadencia = (session: PlannedSession) =>
  session.status !== "changedInIntervals" && session.status !== "removedInIntervals";

/** Whether the session is still the same version as `published`, whatever its status. */
export const isAsPublished = (session: PlannedSession, published: PlannedSession) =>
  session.externalId === published.externalId &&
  session.day === published.day &&
  session.kind === published.kind &&
  session.title === published.title &&
  session.targetMinutes === published.targetMinutes &&
  session.purpose === published.purpose &&
  JSON.stringify(session.workout) === JSON.stringify(published.workout);
