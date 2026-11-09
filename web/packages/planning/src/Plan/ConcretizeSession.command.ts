import { EvidenceSnapshot, Fingerprint } from "@cadencia/athlete/Evidence";
import { Authenticated } from "@cadencia/identity/Authenticated.middleware";
import { NotYours } from "@cadencia/identity/NotYours.rejection";
import { Day } from "@cadencia/kernel/Calendar/Day";
import { PlanId } from "@cadencia/kernel/Plan.id";
import { SessionKind } from "@cadencia/kernel/Training/SessionKind";
import { FtpFraction, Minutes } from "@cadencia/kernel/Training/Units";
import { Workout } from "@cadencia/kernel/Training/Workout";
import * as Domain from "@alchemy.run/domain";
import * as Schema from "effect/Schema";
import { PlannedSession } from "./PlannedSession.ts";
import { PlanNotActive } from "./PlanNotActive.rejection.ts";

/** More riding than the day allows: availability, time away, or the athlete's own limit. */
export class AvailabilityExceeded extends Domain.Rejection(
  "AvailabilityExceeded",
  { day: Day, allowedMinutes: Minutes, proposedMinutes: Minutes },
  { httpApiStatus: 422 },
) {}

/** Readiness can soften a planned session, never harden it beyond the plan. */
export class HardensPlannedSession extends Domain.Rejection(
  "HardensPlannedSession",
  { day: Day, planned: SessionKind, proposed: SessionKind, peakIntensity: FtpFraction },
  { httpApiStatus: 422 },
) {}

/** The plan has no session that day. */
export class DayNotPlanned extends Domain.Rejection("DayNotPlanned", { day: Day }, { httpApiStatus: 422 }) {}

/** Riding stays easy on and right after a confirmed hard gym or CrossFit session. */
export class IntensityAfterHardTraining extends Domain.Rejection(
  "IntensityAfterHardTraining",
  { day: Day, proposed: SessionKind, peakIntensity: FtpFraction },
  { httpApiStatus: 422 },
) {}

/** How a workout's shape contradicts its stated purpose. */
export const PurposeProblem = Schema.Literals([
  "restWithRiding",
  "openerWithoutEvent",
  "openerWithoutActivation",
  "openerMostlyIntense",
  "openerWithoutWarmUp",
  "openerTooMuchActivation",
  "openerEffortTooLong",
  "openerRecoveryTooShort",
  "openerWithoutFinalRecovery",
  "effortBeyondReach",
]);
export type PurposeProblem = typeof PurposeProblem.Type;

/** The workout's shape contradicts its stated purpose: a rest day with riding, a malformed opener, an effort nobody could finish. */
export class PurposeMismatch extends Domain.Rejection(
  "PurposeMismatch",
  { day: Day, problem: PurposeProblem },
  { httpApiStatus: 422 },
) {}

export class SessionConcretized extends Domain.Event("SessionConcretized", {
  session: PlannedSession,
  softened: Schema.Boolean,
  fingerprint: Fingerprint,
}) {}

/** Turn a planned day into a concrete workout, within the plan's limits. */
export class ConcretizeSession extends Domain.Command("ConcretizeSession", {
  target: PlanId,
  middleware: [Authenticated],
  input: { day: Day, workout: Workout, evidence: EvidenceSnapshot },
  events: [SessionConcretized],
  rejects: [
    PlanNotActive,
    DayNotPlanned,
    AvailabilityExceeded,
    IntensityAfterHardTraining,
    HardensPlannedSession,
    PurposeMismatch,
    NotYours,
  ],
}) {}
