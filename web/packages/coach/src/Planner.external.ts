import { Day } from "@cadencia/kernel/Day";
import { EvidenceSnapshot } from "@cadencia/kernel/Evidence";
import { Workout } from "@cadencia/kernel/Workout";
import * as Domain from "@alchemy.run/domain";
import * as Schema from "effect/Schema";
import { DayLimit, PlanAnswer } from "./CoachShape.ts";
import { PlanDraft } from "./Consultation/PlanDraft.ts";

/**
 * The Planning model, in the coach's language. The coach proposes; Planning
 * decides with its own rules and answers whether it accepted.
 */
export class Planner extends Domain.ExternalSystem("Planner", {
  concretizeSession: {
    args: { planId: Schema.String, day: Day, workout: Workout, evidence: EvidenceSnapshot },
    success: PlanAnswer.fields,
  },
  reviseWeek: {
    args: { planId: Schema.String, limits: Schema.Array(DayLimit) },
    success: PlanAnswer.fields,
  },
  createPlan: {
    args: { planId: Schema.String, draft: PlanDraft },
    success: PlanAnswer.fields,
  },
}) {}
