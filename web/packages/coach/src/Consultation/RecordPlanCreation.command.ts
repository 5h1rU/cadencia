import { PlanId } from "@cadencia/kernel/Plan.id";
import * as Domain from "@alchemy.run/domain";
import { PlanAnswer } from "../PlanAnswer.ts";
import { Refusal } from "../Refusal.ts";
import { ConsultationId } from "./Consultation.id.ts";

export class PlanCreatedFromDraft extends Domain.Event("PlanCreatedFromDraft", { planId: PlanId }) {}
export class DraftRefusedByPlan extends Domain.Event("DraftRefusedByPlan", { refusal: Refusal }) {}

/** Record what Planning did with the accepted draft. Sent by `PlanFromConsultation`; it never rejects. */
export class RecordPlanCreation extends Domain.Command("RecordPlanCreation", {
  target: ConsultationId,
  input: { answer: PlanAnswer },
  events: [PlanCreatedFromDraft, DraftRefusedByPlan],
}) {}
