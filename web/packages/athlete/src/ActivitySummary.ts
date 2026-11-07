import { Day } from "@cadencia/kernel/Calendar/Day";
import { Title } from "@cadencia/kernel/Text";
import { Kilometers, Seconds } from "@cadencia/kernel/Training/Units";
import * as Schema from "effect/Schema";
import { IntervalsActivityId } from "./Activity.id.ts";
import { Bpm, Rpe, TrainingLoad, Watts } from "./Measures.ts";

/**
 * An activity the athlete recorded in Intervals.icu, in Cadencia's terms. Each
 * measure is null when Intervals has none, or none Cadencia can use.
 */
export const ActivitySummary = Schema.Struct({
  activityId: IntervalsActivityId,
  /** The athlete's local day it started on. */
  day: Schema.NullOr(Day),
  /** The name any app, or the athlete, gave it. */
  name: Schema.NullOr(Title),
  movingTime: Schema.NullOr(Seconds),
  distance: Schema.NullOr(Kilometers),
  trainingLoad: Schema.NullOr(TrainingLoad),
  averagePower: Schema.NullOr(Watts),
  /** Intervals' weighted average power. */
  normalizedPower: Schema.NullOr(Watts),
  averageHeartRate: Schema.NullOr(Bpm),
  rpe: Schema.NullOr(Rpe),
});
export type ActivitySummary = typeof ActivitySummary.Type;
