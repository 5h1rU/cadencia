import type { Workout } from "@cadencia/kernel/Training/Workout";

const percent = (intensity: number) => Math.round(intensity * 100);
const floorPercent = (intensity: number) => Math.floor(intensity * 100 + 0.000001);

const duration = (seconds: number): string => {
  const total = Math.round(seconds);
  const m = Math.floor(total / 60);
  const s = total % 60;
  return s === 0 ? `${m}m` : m === 0 ? `${s}s` : `${m}m${s}s`;
};

/**
 * The workout in Intervals.icu's workout-builder text, as Cadencia iOS writes
 * it: one block per step, percentages of FTP, ramps as `ramp a-b%`.
 */
export const workoutText = (workout: Workout): string => {
  const ceiling = workout.intensityCeiling;
  const target = (intensity: number) =>
    ceiling === null ? percent(intensity) : floorPercent(Math.min(intensity, ceiling));
  const blocks = workout.steps.map((step) => {
    const start = target(step.startIntensity);
    const end = target(step.endIntensity);
    let line = `- ${duration(step.durationSeconds)} ${start === end ? `${start}%` : `ramp ${start}-${end}%`}`;
    if (step.cadenceRpm !== null) line += ` ${step.cadenceRpm}rpm`;
    return `${step.name}\n${line}`;
  });
  const text = blocks.join("\n\n");
  return workout.rationale === null ? text : `${workout.rationale}\n\n${text}`;
};
