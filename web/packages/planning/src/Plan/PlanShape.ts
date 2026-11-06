import { Day } from "@cadencia/kernel/Calendar/Day";
import { Paragraph, Title } from "@cadencia/kernel/Text";
import { SessionKind } from "@cadencia/kernel/Training/SessionKind";
import { Kilometers, Minutes } from "@cadencia/kernel/Training/Units";
import { Workout } from "@cadencia/kernel/Training/Workout";
import * as Schema from "effect/Schema";
import { ExternalId, SessionId } from "./Session.id.ts";

export { GoalKind } from "@cadencia/kernel/Training/Goal";
export { Phase, PhaseFocus } from "@cadencia/kernel/Training/Phase";

/** The day the plan builds towards. */
export const GoalEvent = Schema.Struct({
  name: Title,
  day: Day,
  distanceKm: Schema.NullOr(Kilometers),
  /** A race is ridden at the limit; a group ride or gran fondo is a priority day, not a race effort. */
  isRace: Schema.Boolean,
  objective: Paragraph,
});
export type GoalEvent = typeof GoalEvent.Type;

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

/** What a new plan's sessions look like before they have ids. */
export const SessionDraft = Schema.Struct({
  day: Day,
  kind: SessionKind,
  title: Title,
  targetMinutes: Minutes,
  purpose: Paragraph,
});
export type SessionDraft = typeof SessionDraft.Type;

/** An athlete-authored requirement for one day ("Thursday, 45 minutes at most"). */
export const DayRequirement = Schema.Struct({
  day: Day,
  instructions: Paragraph,
  maxMinutes: Schema.NullOr(Minutes),
});
export type DayRequirement = typeof DayRequirement.Type;
