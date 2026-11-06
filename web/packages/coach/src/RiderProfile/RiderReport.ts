import { Day } from "@cadencia/kernel/Calendar/Day";
import { Paragraph } from "@cadencia/kernel/Text";
import * as Schema from "effect/Schema";
import { Headline } from "../CoachText.ts";
import { Count } from "../Counts.ts";

/** The kind of rider the evidence shows. Raw values match `CyclistProfile.RiderType` in Cadencia iOS. */
export const RiderType = Schema.Literals(["climber", "puncheur", "sprinter", "timeTrialist", "endurance", "allRounder", "developing"]);
export type RiderType = typeof RiderType.Type;

/** How much the evidence supports the profile. */
export const Confidence = Schema.Literals(["limited", "moderate", "high"]);
export type Confidence = typeof Confidence.Type;

/** The AI's reading of the rider's demonstrated tendencies. */
export const RiderReport = Schema.Struct({
  riderType: RiderType,
  confidence: Confidence,
  headline: Headline,
  summary: Paragraph,
  strengths: Schema.Array(Paragraph),
  development: Schema.Array(Paragraph),
  evidence: Schema.Array(Paragraph),
  caveats: Schema.Array(Paragraph),
  oldest: Day,
  newest: Day,
  rideCount: Count,
}).pipe(Schema.check(Schema.makeFilter((r) => (r.oldest <= r.newest ? undefined : "the oldest ride comes before the newest"))));
export type RiderReport = typeof RiderReport.Type;
