import { Day } from "@cadencia/kernel/Day";
import { SessionKind } from "@cadencia/kernel/SessionKind";
import { Workout } from "@cadencia/kernel/Workout";
import * as Schema from "effect/Schema";

/** What the plan is training for. Raw values match `GoalKind` in Cadencia iOS. */
export const GoalKind = Schema.Literals([
  "climbing",
  "ftp",
  "durability",
  "endurance",
  "vo2max",
  "event",
  "strength",
]);
export type GoalKind = typeof GoalKind.Type;

export const PhaseFocus = Schema.Literals([
  "prepare",
  "base",
  "build",
  "peak",
  "taper",
  "consolidate",
  "recover",
]);

/** A block of weeks with one focus. Weeks are 1-based from the plan's start. */
export const Phase = Schema.Struct({
  focus: PhaseFocus,
  startWeek: Schema.Int,
  endWeek: Schema.Int,
  summary: Schema.String,
});
export type Phase = typeof Phase.Type;

/** The day the plan builds towards. */
export const GoalEvent = Schema.Struct({
  name: Schema.String,
  day: Day,
  distanceKm: Schema.NullOr(Schema.Number),
  /** A race is ridden at the limit; a group ride or gran fondo is a priority day, not a race effort. */
  isRace: Schema.Boolean,
  objective: Schema.String,
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
  sessionId: Schema.String,
  day: Day,
  kind: SessionKind,
  title: Schema.String,
  targetMinutes: Schema.Int,
  purpose: Schema.String,
  status: SessionStatus,
  workout: Schema.NullOr(Workout),
  /** The Intervals `external_id` this session is published under. */
  externalId: Schema.String,
});
export type PlannedSession = typeof PlannedSession.Type;

/** What a new plan's sessions look like before they have ids. */
export const SessionDraft = Schema.Struct({
  day: Day,
  kind: SessionKind,
  title: Schema.String,
  targetMinutes: Schema.Int,
  purpose: Schema.String,
});
export type SessionDraft = typeof SessionDraft.Type;

/** An athlete-authored requirement for one day ("Thursday, 45 minutes at most"). */
export const DayRequirement = Schema.Struct({
  day: Day,
  instructions: Schema.String,
  maxMinutes: Schema.NullOr(Schema.Int),
});
export type DayRequirement = typeof DayRequirement.Type;

/** The `external_id` of a plan session in Intervals. The prefix is the one Cadencia iOS uses. */
export const externalIdFor = (planId: string, sessionId: string): string =>
  `cadencia-${planId.replace(":", "-")}-${sessionId}`;
