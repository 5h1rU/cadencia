import { Day } from "@cadencia/kernel/Calendar/Day";
import { Paragraph } from "@cadencia/kernel/Text";
import { Seconds } from "@cadencia/kernel/Training/Units";
import * as Schema from "effect/Schema";
import { Bpm, HrvMs, Kilograms, TrainingLoad, WellnessScale } from "./Measures.ts";

/**
 * One day of the athlete's wellness in Intervals.icu, in Cadencia's terms.
 * Each value is null when Intervals has none, or none Cadencia can use.
 */
export const WellnessDay = Schema.Struct({
  day: Day,
  /** Fitness: Intervals' chronic training load (CTL). */
  fitness: Schema.NullOr(TrainingLoad),
  /** Fatigue: Intervals' acute training load (ATL). */
  acuteLoad: Schema.NullOr(TrainingLoad),
  weight: Schema.NullOr(Kilograms),
  restingHeartRate: Schema.NullOr(Bpm),
  hrv: Schema.NullOr(HrvMs),
  sleep: Schema.NullOr(Seconds),
  sleepQuality: Schema.NullOr(WellnessScale),
  soreness: Schema.NullOr(WellnessScale),
  fatigue: Schema.NullOr(WellnessScale),
  stress: Schema.NullOr(WellnessScale),
  mood: Schema.NullOr(WellnessScale),
  motivation: Schema.NullOr(WellnessScale),
  injury: Schema.NullOr(WellnessScale),
  comments: Schema.NullOr(Paragraph),
});
export type WellnessDay = typeof WellnessDay.Type;

/**
 * What the athlete may declare about a day, each in Intervals' unit. Fields
 * left out stay as they are in Intervals.
 */
export const WellnessDeclaration = Schema.Struct({
  weight: Schema.optional(Kilograms),
  sleepQuality: Schema.optional(WellnessScale),
  soreness: Schema.optional(WellnessScale),
  fatigue: Schema.optional(WellnessScale),
  stress: Schema.optional(WellnessScale),
  mood: Schema.optional(WellnessScale),
  motivation: Schema.optional(WellnessScale),
  injury: Schema.optional(WellnessScale),
  comments: Schema.optional(Paragraph),
});
export type WellnessDeclaration = typeof WellnessDeclaration.Type;
