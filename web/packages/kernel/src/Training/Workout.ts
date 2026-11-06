import * as Schema from "effect/Schema";
import { SessionKind } from "./SessionKind.ts";
import { Paragraph, Title } from "../Text.ts";
import { CadenceRpm, FtpFraction, Seconds } from "./Units.ts";

/** One block of a structured workout. A ramp has different start and end intensities. */
export const WorkoutStep = Schema.Struct({
  name: Title,
  durationSeconds: Seconds.pipe(Schema.check(Schema.isGreaterThan(0))),
  startIntensity: FtpFraction,
  endIntensity: FtpFraction,
  cadenceRpm: Schema.NullOr(CadenceRpm),
});
export type WorkoutStep = typeof WorkoutStep.Type;

/** A trainer-ready session: its purpose and its blocks. */
export const Workout = Schema.Struct({
  name: Title,
  kind: SessionKind,
  steps: Schema.Array(WorkoutStep),
  /** Hard ceiling for the whole session; the trainer never targets above it. */
  intensityCeiling: Schema.NullOr(FtpFraction),
  /** Why this workout, when the coach said why. */
  rationale: Schema.NullOr(Paragraph),
});
export type Workout = typeof Workout.Type;

export const totalSeconds = (workout: Workout): number =>
  workout.steps.reduce((sum, step) => sum + step.durationSeconds, 0);

export const totalMinutes = (workout: Workout): number => totalSeconds(workout) / 60;

/** The highest intensity any block reaches. */
export const peakIntensity = (workout: Workout): FtpFraction =>
  FtpFraction.make(workout.steps.reduce((peak, step) => Math.max(peak, step.startIntensity, step.endIntensity), 0));
