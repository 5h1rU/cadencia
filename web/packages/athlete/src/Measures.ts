import * as Schema from "effect/Schema";

// What Intervals.icu measures about an athlete, in the units Cadencia reads
// and writes them in. Each is bounded to what a cyclist can have.

/** A functional threshold power, in watts. */
export const FtpWatts = Schema.Int.pipe(Schema.check(Schema.isBetween({ minimum: 30, maximum: 700 })), Schema.brand("FtpWatts"));
export type FtpWatts = typeof FtpWatts.Type;

/** A power reading, in watts. */
export const Watts = Schema.Number.pipe(
  Schema.check(Schema.isFinite(), Schema.isBetween({ minimum: 0, maximum: 3000 })),
  Schema.brand("Watts"),
);
export type Watts = typeof Watts.Type;

/** Body weight, in kilograms. */
export const Kilograms = Schema.Number.pipe(
  Schema.check(Schema.isFinite(), Schema.isBetween({ minimum: 20, maximum: 350 })),
  Schema.brand("Kilograms"),
);
export type Kilograms = typeof Kilograms.Type;

/** A heart rate, in beats per minute. */
export const Bpm = Schema.Int.pipe(Schema.check(Schema.isBetween({ minimum: 20, maximum: 250 })), Schema.brand("Bpm"));
export type Bpm = typeof Bpm.Type;

/** Heart-rate variability (rMSSD), in milliseconds. */
export const HrvMs = Schema.Number.pipe(
  Schema.check(Schema.isFinite(), Schema.isBetween({ minimum: 0, maximum: 500 })),
  Schema.brand("HrvMs"),
);
export type HrvMs = typeof HrvMs.Type;

/** Training load, fitness (CTL) or fatigue (ATL), in Intervals.icu's load units. */
export const TrainingLoad = Schema.Number.pipe(
  Schema.check(Schema.isFinite(), Schema.isBetween({ minimum: 0, maximum: 2000 })),
  Schema.brand("TrainingLoad"),
);
export type TrainingLoad = typeof TrainingLoad.Type;

/** Intervals.icu's subjective wellness scale: 1 … 4. */
export const WellnessScale = Schema.Int.pipe(Schema.check(Schema.isBetween({ minimum: 1, maximum: 4 })), Schema.brand("WellnessScale"));
export type WellnessScale = typeof WellnessScale.Type;

/** Rate of perceived exertion on Intervals.icu's 1 … 10 scale. */
export const Rpe = Schema.Int.pipe(Schema.check(Schema.isBetween({ minimum: 1, maximum: 10 })), Schema.brand("Rpe"));
export type Rpe = typeof Rpe.Type;
