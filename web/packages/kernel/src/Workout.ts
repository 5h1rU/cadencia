import * as Schema from "effect/Schema";
import { SessionKind } from "./SessionKind.ts";

/** Fraction of FTP: 0.65 is 65 %. */
export const Intensity = Schema.Number.pipe(Schema.check(Schema.isBetween({ minimum: 0, maximum: 3 })));

/** One block of a structured workout. A ramp has different start and end intensities. */
export const WorkoutStep = Schema.Struct({
  name: Schema.String,
  durationSeconds: Schema.Number.pipe(Schema.check(Schema.isGreaterThan(0))),
  startIntensity: Intensity,
  endIntensity: Intensity,
  cadenceRpm: Schema.optional(Schema.Int),
});
export type WorkoutStep = typeof WorkoutStep.Type;

/** A trainer-ready session: its purpose and its blocks. */
export const Workout = Schema.Struct({
  name: Schema.String,
  kind: SessionKind,
  steps: Schema.Array(WorkoutStep),
  /** Hard ceiling for the whole session as a fraction of FTP. */
  intensityCeiling: Schema.optional(Intensity),
  rationale: Schema.String,
});
export type Workout = typeof Workout.Type;

export const totalSeconds = (workout: Workout): number =>
  workout.steps.reduce((sum, step) => sum + step.durationSeconds, 0);

export const totalMinutes = (workout: Workout): number => totalSeconds(workout) / 60;

/** The highest intensity any block reaches. */
export const peakIntensity = (workout: Workout): number =>
  workout.steps.reduce((peak, step) => Math.max(peak, step.startIntensity, step.endIntensity), 0);
