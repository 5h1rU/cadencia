import { Day } from "@cadencia/kernel/Day";
import * as Schema from "effect/Schema";

/** The AI's reading of the rider's demonstrated tendencies. Matches `CyclistProfile.Report` in Cadencia iOS. */
export const RiderReport = Schema.Struct({
  riderType: Schema.Literals(["climber", "puncheur", "sprinter", "timeTrialist", "endurance", "allRounder", "developing"]),
  confidence: Schema.Literals(["limited", "moderate", "high"]),
  headline: Schema.String,
  summary: Schema.String,
  strengths: Schema.Array(Schema.String),
  development: Schema.Array(Schema.String),
  evidence: Schema.Array(Schema.String),
  caveats: Schema.Array(Schema.String),
  oldest: Day,
  newest: Day,
  rideCount: Schema.Int,
});
export type RiderReport = typeof RiderReport.Type;
