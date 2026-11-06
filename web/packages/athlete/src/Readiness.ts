import { Paragraph } from "@cadencia/kernel/Text";
import * as Schema from "effect/Schema";

/** How ready the athlete is to absorb intensity. */
export const ReadinessLevel = Schema.Literals(["rest", "easy", "normal", "strong"]);
export type ReadinessLevel = typeof ReadinessLevel.Type;

/** Cadencia's readiness score: 0 (rest) … 100 (strong). */
export const ReadinessScore = Schema.Int.pipe(
  Schema.check(Schema.isBetween({ minimum: 0, maximum: 100 })),
  Schema.brand("ReadinessScore"),
);
export type ReadinessScore = typeof ReadinessScore.Type;

/** Readiness as Cadencia worked it out from the athlete's wellness. */
export const Readiness = Schema.Struct({
  level: ReadinessLevel,
  score: ReadinessScore,
  summary: Paragraph,
});
export type Readiness = typeof Readiness.Type;
