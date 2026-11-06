import { addDays, type Day } from "@cadencia/kernel/Day";
import { conditionsOn, type EvidenceSnapshot } from "@cadencia/kernel/Evidence";
import { isEasy, isHard } from "@cadencia/kernel/SessionKind";
import { peakIntensity, totalMinutes, totalSeconds, type Workout, type WorkoutStep } from "@cadencia/kernel/Workout";
import type { DayRequirement, GoalEvent, PlannedSession } from "./PlanShape.ts";

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

export type Problem =
  | { readonly _tag: "AvailabilityExceeded"; readonly allowedMinutes: number; readonly proposedMinutes: number }
  | { readonly _tag: "IntensityAfterHardTraining"; readonly peakIntensity: number }
  | { readonly _tag: "HardensPlannedSession"; readonly peakIntensity: number }
  | { readonly _tag: "PurposeMismatch"; readonly reason: string };

/** Minutes of riding the day allows: the plan, Intervals availability and the athlete's own limit. */
export const allowedMinutes = (
  session: PlannedSession,
  evidence: EvidenceSnapshot,
  requirement: DayRequirement | undefined,
): number => {
  const conditions = conditionsOn(evidence, session.day);
  if (conditions?.unavailable) return 0;
  return Math.min(
    session.targetMinutes,
    conditions?.maxMinutes ?? Number.POSITIVE_INFINITY,
    requirement?.maxMinutes ?? Number.POSITIVE_INFINITY,
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
  const peak = peakIntensity(workout);

  if (workout.kind === "rest" && workout.steps.length > 0) {
    return { _tag: "PurposeMismatch", reason: "A rest day must have no riding blocks." };
  }
  const allowed = allowedMinutes(session, evidence, requirement);
  if (workout.kind !== "rest" && allowed === 0) {
    return { _tag: "AvailabilityExceeded", allowedMinutes: 0, proposedMinutes: minutes };
  }
  if (minutes > allowed + 0.1) {
    return { _tag: "AvailabilityExceeded", allowedMinutes: allowed, proposedMinutes: minutes };
  }
  const intense = isHard(workout.kind) || peak > EASY_RIDING_INTENSITY;
  if (conditionsOn(evidence, day)?.hardOtherTraining && intense) {
    return { _tag: "IntensityAfterHardTraining", peakIntensity: peak };
  }
  if (isEasy(session.kind) && intense) {
    return { _tag: "HardensPlannedSession", peakIntensity: peak };
  }
  if (workout.kind === "openerActivation") {
    const tomorrow = addDays(day, 1);
    const eventTomorrow = evidence.eventDays.includes(tomorrow) || goalEvent?.day === tomorrow;
    if (!eventTomorrow) {
      return {
        _tag: "PurposeMismatch",
        reason: "An opener requires a confirmed event the following day. Choose the actual training purpose otherwise.",
      };
    }
    const reason = openerProblem(workout);
    if (reason) return { _tag: "PurposeMismatch", reason };
  }
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
export const openerProblem = (workout: Workout): string | undefined => {
  const slices = workout.steps.flatMap(slicesOf);
  const total = totalSeconds(workout);
  const sum = (kinds: ReadonlyArray<SliceKind>) =>
    slices.filter((s) => kinds.includes(s.kind)).reduce((acc, s) => acc + s.seconds, 0);
  const activation = sum(["activation"]);
  if (activation <= 0) {
    return "An opener needs brief near-threshold or above-threshold activation. Label an easy-only alternative endurance or recovery and explain why.";
  }
  if (sum(["activation", "other"]) >= total / 2) {
    return "An opener must be mostly easy riding, not a sustained tempo or threshold session with brief efforts added.";
  }
  if (slices[0]?.kind === "activation") return "Include an easy warm-up before the first activation.";
  if (activation > total * MAX_ACTIVATION_FRACTION + 0.001) {
    return "Activation occupies too much of the opener. Reduce intensity exposure and preserve mostly easy riding.";
  }
  let effort = 0;
  let recovery = 0;
  for (const slice of slices) {
    if (slice.kind === "activation") {
      if (effort > 0 && recovery > 0) {
        if (recovery + 0.001 < effort) {
          return "Give each activation at least its own duration in easy recovery before the next effort.";
        }
        effort = 0;
        recovery = 0;
      }
      effort += slice.seconds;
      if (effort > MAX_CONTINUOUS_ACTIVATION_SECONDS + 0.001) {
        return "An opener activation is too long. Use brief efforts, not sustained training intervals.";
      }
    } else if (slice.kind === "easy" && effort > 0) {
      recovery += slice.seconds;
    }
  }
  if (recovery + 0.001 < effort) return "Finish the final activation with full easy recovery and a cool-down.";
  return undefined;
};

/** True when the proposal rides less, or differently, than the plan asked: readiness softened it. */
export const isSoftened = (session: PlannedSession, workout: Workout): boolean =>
  session.kind !== workout.kind || totalMinutes(workout) + 0.1 < session.targetMinutes;

export type { Day };
