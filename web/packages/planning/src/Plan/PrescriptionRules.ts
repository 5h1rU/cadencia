import { conditionsOn, type EvidenceSnapshot } from "@cadencia/athlete/Evidence";
import { addDays, type Day } from "@cadencia/kernel/Calendar/Day";
import type { SessionKind } from "@cadencia/kernel/Training/SessionKind";
import { type FtpFraction, Minutes } from "@cadencia/kernel/Training/Units";
import {
  peakIntensity,
  totalMinutes,
  totalSeconds,
  type Workout,
  type WorkoutStep,
} from "@cadencia/kernel/Training/Workout";
import type { PurposeProblem } from "./ConcretizeSession.command.ts";
import type { DayRequirement } from "./DayRequirement.ts";
import type { GoalEvent } from "./GoalEvent.ts";
import type { PlannedSession } from "./PlannedSession.ts";

/**
 * Product-wide checks on a proposed workout, ported from `PrescriptionValidator`
 * in Cadencia iOS. Conservative bounds on the stated purpose, not templates:
 * the AI still chooses the dose from the athlete's evidence.
 */
export const ACTIVATION_INTENSITY = 0.9;
export const EASY_RECOVERY_INTENSITY = 0.6;
export const EASY_RIDING_INTENSITY = 0.75;
export const MAX_CONTINUOUS_ACTIVATION_SECONDS = 3 * 60;
export const MAX_ACTIVATION_FRACTION = 0.2;

/** Kinds that load the athlete with sustained intensity. */
const isHard = (kind: SessionKind): boolean =>
  kind === "tempo" || kind === "threshold" || kind === "vo2max" || kind === "race";

/** Kinds whose purpose is easy riding: a proposal for one of these days may not add intensity. */
const isEasy = (kind: SessionKind): boolean => kind === "recovery" || kind === "endurance" || kind === "longRide";

/**
 * How demanding each kind's purpose is, for the kinds whose purpose sets it.
 * A group ride, strength or an opener has no place on this ladder.
 */
const DEMAND: Partial<Record<SessionKind, number>> = {
  recovery: 1,
  endurance: 2,
  longRide: 2,
  tempo: 3,
  threshold: 4,
  vo2max: 5,
  race: 6,
};

/** The highest intensity, as a fraction of FTP, a hard kind's purpose reaches. VO₂max and races have none. */
const PEAK_CEILING: Partial<Record<SessionKind, number>> = { tempo: 1.0, threshold: 1.1 };

/**
 * The highest average intensity a whole session of the kind reaches, warm-up
 * and recoveries included. It bounds the dose: a session can stay under its
 * kind's peak and still ask far more than the kind does, by never easing off.
 */
const MEAN_CEILING: Partial<Record<SessionKind, number>> = { tempo: 0.85, threshold: 0.95 };

/**
 * How much work above FTP one unbroken effort may ask, in seconds times the
 * fraction of FTP above it: 600 is ten minutes at 200 %, or an hour at 117 %.
 * A trained rider has between 60 and 120, so only an effort nobody could
 * finish is refused, on any day and for any kind.
 */
export const SUPRA_FTP_BUDGET = 600;

/** The session's average intensity, by time. */
const meanIntensity = (workout: Workout): number => {
  const seconds = totalSeconds(workout);
  if (seconds === 0) return 0;
  return workout.steps.reduce((sum, s) => sum + ((s.startIntensity + s.endIntensity) / 2) * s.durationSeconds, 0) / seconds;
};

/** A step's work above FTP: the area between its intensity and FTP, where it is above. */
const workAboveFtp = (step: WorkoutStep): number => {
  const low = Math.min(step.startIntensity, step.endIntensity);
  const high = Math.max(step.startIntensity, step.endIntensity);
  if (high <= 1) return 0;
  if (low >= 1) return ((low + high) / 2 - 1) * step.durationSeconds;
  // A ramp that crosses FTP: the triangle above it.
  return ((high - 1) / 2) * ((high - 1) / (high - low)) * step.durationSeconds;
};

/** Whether some unbroken effort above FTP asks more than anyone has. A step at or under FTP ends the effort. */
const isBeyondReach = (workout: Workout): boolean => {
  let effort = 0;
  for (const step of workout.steps) {
    const work = workAboveFtp(step);
    effort = work === 0 ? 0 : effort + work;
    if (effort > SUPRA_FTP_BUDGET) return true;
  }
  return false;
};

/**
 * Whether a proposal asks more of the athlete than the planned session's
 * purpose: intensity on an easy day or on a strength day (the gym is that
 * day's load), anything but an opener's brief efforts on an opener day, and on
 * a hard day a harder kind, efforts above the kind's peak, or a session that
 * averages above the kind's dose. A group ride is left to the athlete.
 */
const hardens = (planned: SessionKind, workout: Workout, intense: boolean, peak: number): boolean => {
  if (isEasy(planned) || planned === "strength") return intense;
  if (planned === "openerActivation") return intense && workout.kind !== "openerActivation";
  const demand = DEMAND[planned];
  if (demand === undefined) return false;
  return (
    (DEMAND[workout.kind] ?? 0) > demand ||
    peak > (PEAK_CEILING[planned] ?? Number.POSITIVE_INFINITY) ||
    meanIntensity(workout) > (MEAN_CEILING[planned] ?? Number.POSITIVE_INFINITY)
  );
};

export type Problem =
  | { readonly _tag: "AvailabilityExceeded"; readonly allowedMinutes: Minutes; readonly proposedMinutes: Minutes }
  | { readonly _tag: "IntensityAfterHardTraining"; readonly peakIntensity: FtpFraction }
  | { readonly _tag: "HardensPlannedSession"; readonly peakIntensity: FtpFraction }
  | { readonly _tag: "PurposeMismatch"; readonly problem: PurposeProblem };

/** Minutes of riding the day allows: the plan, Intervals availability and the athlete's own limit. */
export const allowedMinutes = (
  session: PlannedSession,
  evidence: EvidenceSnapshot,
  requirement: DayRequirement | undefined,
): Minutes => {
  const conditions = conditionsOn(evidence, session.day);
  if (conditions?.unavailable) return Minutes.make(0);
  return Minutes.make(
    Math.min(
      session.targetMinutes,
      conditions?.maxMinutes ?? Number.POSITIVE_INFINITY,
      requirement?.maxMinutes ?? Number.POSITIVE_INFINITY,
    ),
  );
};

/** The first rule a proposal for a planned day breaks, if any. */
export const problemWith = (input: {
  readonly session: PlannedSession;
  readonly workout: Workout;
  readonly evidence: EvidenceSnapshot;
  readonly requirement: DayRequirement | undefined;
  readonly goalEvent: GoalEvent | null;
}): Problem | undefined => {
  const { session, workout, evidence, requirement, goalEvent } = input;
  const day = session.day;
  const minutes = totalMinutes(workout);
  const proposed = Minutes.make(Math.min(1440, Math.ceil(minutes - 0.1)));
  const peak = peakIntensity(workout);

  if (workout.kind === "rest" && workout.steps.length > 0) {
    return { _tag: "PurposeMismatch", problem: "restWithRiding" };
  }
  const allowed = allowedMinutes(session, evidence, requirement);
  if (workout.kind !== "rest" && allowed === 0) {
    return { _tag: "AvailabilityExceeded", allowedMinutes: allowed, proposedMinutes: proposed };
  }
  if (minutes > allowed + 0.1) {
    return { _tag: "AvailabilityExceeded", allowedMinutes: allowed, proposedMinutes: proposed };
  }
  const intense = isHard(workout.kind) || peak > EASY_RIDING_INTENSITY;
  if (conditionsOn(evidence, day)?.hardOtherTraining && intense) {
    return { _tag: "IntensityAfterHardTraining", peakIntensity: peak };
  }
  if (hardens(session.kind, workout, intense, peak)) {
    return { _tag: "HardensPlannedSession", peakIntensity: peak };
  }
  if (workout.kind === "openerActivation") {
    const tomorrow = addDays(day, 1);
    const eventTomorrow = evidence.eventDays.includes(tomorrow) || goalEvent?.day === tomorrow;
    if (!eventTomorrow) return { _tag: "PurposeMismatch", problem: "openerWithoutEvent" };
    const problem = openerProblem(workout);
    if (problem) return { _tag: "PurposeMismatch", problem };
  }
  if (isBeyondReach(workout)) return { _tag: "PurposeMismatch", problem: "effortBeyondReach" };
  return undefined;
};

type SliceKind = "activation" | "easy" | "endurance" | "other";
interface Slice {
  readonly kind: SliceKind;
  readonly seconds: number;
}

/** Split a ramp where it crosses the zone thresholds, so a long effort can't hide across steps. */
const slicesOf = (step: WorkoutStep): Array<Slice> => {
  const a = step.startIntensity;
  const b = step.endIntensity;
  const fractions = [0, 1];
  if (a !== b) {
    for (const threshold of [ACTIVATION_INTENSITY, EASY_RECOVERY_INTENSITY, EASY_RIDING_INTENSITY]) {
      const crossing = (threshold - a) / (b - a);
      if (crossing > 0 && crossing < 1) fractions.push(crossing);
    }
  }
  fractions.sort((x, y) => x - y);
  const slices: Array<Slice> = [];
  for (let i = 0; i < fractions.length - 1; i++) {
    const start = fractions[i]!;
    const end = fractions[i + 1]!;
    const intensity = a + ((b - a) * (start + end)) / 2;
    const kind: SliceKind =
      intensity >= ACTIVATION_INTENSITY
        ? "activation"
        : intensity <= EASY_RECOVERY_INTENSITY
          ? "easy"
          : intensity <= EASY_RIDING_INTENSITY
            ? "endurance"
            : "other";
    slices.push({ kind, seconds: (end - start) * step.durationSeconds });
  }
  return slices;
};

/** Why an opener's shape doesn't fit its purpose, if it doesn't. */
export const openerProblem = (workout: Workout): PurposeProblem | undefined => {
  const slices = workout.steps.flatMap(slicesOf);
  const total = totalSeconds(workout);
  const sum = (kinds: ReadonlyArray<SliceKind>) =>
    slices.filter((s) => kinds.includes(s.kind)).reduce((acc, s) => acc + s.seconds, 0);
  const activation = sum(["activation"]);
  if (activation <= 0) return "openerWithoutActivation";
  if (sum(["activation", "other"]) >= total / 2) return "openerMostlyIntense";
  if (slices[0]?.kind === "activation") return "openerWithoutWarmUp";
  if (activation > total * MAX_ACTIVATION_FRACTION + 0.001) return "openerTooMuchActivation";
  let effort = 0;
  let recovery = 0;
  for (const slice of slices) {
    if (slice.kind === "activation") {
      if (effort > 0 && recovery > 0) {
        if (recovery + 0.001 < effort) return "openerRecoveryTooShort";
        effort = 0;
        recovery = 0;
      }
      effort += slice.seconds;
      if (effort > MAX_CONTINUOUS_ACTIVATION_SECONDS + 0.001) return "openerEffortTooLong";
    } else if (slice.kind === "easy" && effort > 0) {
      recovery += slice.seconds;
    }
  }
  if (recovery + 0.001 < effort) return "openerWithoutFinalRecovery";
  return undefined;
};

/** True when the proposal rides less, or differently, than the plan asked: readiness softened it. */
export const isSoftened = (session: PlannedSession, workout: Workout): boolean =>
  session.kind !== workout.kind || totalMinutes(workout) + 0.1 < session.targetMinutes;

export type { Day };
