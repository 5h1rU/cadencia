import * as Domain from "@alchemy.run/domain";
import { PlanAnswer } from "../PlanAnswer.ts";
import { Attempt } from "./Attempt.ts";
import { DailyDecisionId } from "./DailyDecision.id.ts";

export class PlanVerdictRecorded extends Domain.Event("PlanVerdictRecorded", {
  attempt: Attempt,
  answer: PlanAnswer,
}) {}

/** Record whether Planning accepted an attempt, once per attempt. Sent by `DecisionToPlan`; it never rejects. */
export class RecordPlanVerdict extends Domain.Command("RecordPlanVerdict", {
  target: DailyDecisionId,
  input: { attempt: Attempt, answer: PlanAnswer },
  events: [PlanVerdictRecorded],
}) {}
