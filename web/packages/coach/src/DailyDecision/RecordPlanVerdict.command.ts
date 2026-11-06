import * as Domain from "@alchemy.run/domain";
import * as Schema from "effect/Schema";
import { DailyDecisionId } from "./DailyDecision.id.ts";

export class PlanVerdictRecorded extends Domain.Event("PlanVerdictRecorded", {
  attempt: Schema.Int,
  accepted: Schema.Boolean,
  reason: Schema.NullOr(Schema.String),
}) {}

/** Record whether Planning accepted an attempt. Sent by `DecisionToPlan`; it never rejects. */
export class RecordPlanVerdict extends Domain.Command("RecordPlanVerdict", {
  target: DailyDecisionId,
  input: { attempt: Schema.Int, accepted: Schema.Boolean, reason: Schema.NullOr(Schema.String) },
  events: [PlanVerdictRecorded],
}) {}
