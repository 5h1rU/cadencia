import * as Schema from "effect/Schema";
import { Day } from "./Day.ts";

/** A stable hash of the evidence a decision was made from. A different one means the evidence changed. */
export const Fingerprint = Schema.String.pipe(Schema.brand("Fingerprint"));
export type Fingerprint = typeof Fingerprint.Type;

/** How ready the athlete is to absorb intensity, as Cadencia iOS computes it. */
export const ReadinessLevel = Schema.Literals(["rest", "easy", "normal", "strong"]);
export type ReadinessLevel = typeof ReadinessLevel.Type;

export const Readiness = Schema.Struct({
  level: ReadinessLevel,
  /** 0…100. */
  score: Schema.Int,
  summary: Schema.String,
});
export type Readiness = typeof Readiness.Type;

/** What Intervals.icu says about one day: availability, time away and other training. */
export const DayConditions = Schema.Struct({
  day: Day,
  /** Riding minutes available that day; null when Intervals sets no limit. */
  maxMinutes: Schema.NullOr(Schema.Int),
  /** Holiday, sickness, injury or an unavailable day. */
  unavailable: Schema.Boolean,
  /** A hard gym or CrossFit session that day or the day before. */
  hardOtherTraining: Schema.Boolean,
});
export type DayConditions = typeof DayConditions.Type;

/**
 * The evidence a proposal was made from, captured where the AI ran. The domain
 * cannot read Intervals inside a decision, so every proposal carries it.
 */
export const EvidenceSnapshot = Schema.Struct({
  fingerprint: Fingerprint,
  readiness: Readiness,
  days: Schema.Array(DayConditions),
  /** Days with a confirmed goal event (Intervals RACE_A/B/C). */
  eventDays: Schema.Array(Day),
});
export type EvidenceSnapshot = typeof EvidenceSnapshot.Type;

export const conditionsOn = (evidence: EvidenceSnapshot, day: Day): DayConditions | undefined =>
  evidence.days.find((d) => d.day === day);
