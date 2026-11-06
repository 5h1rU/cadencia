import { EvidenceSnapshot } from "@cadencia/athlete/Evidence";
import { Day } from "@cadencia/kernel/Calendar/Day";
import { PlanId } from "@cadencia/kernel/Plan.id";
import { Workout } from "@cadencia/kernel/Training/Workout";
import * as Domain from "@alchemy.run/domain";
import * as Schema from "effect/Schema";
import { DayLimit, PlanAnswer } from "./CoachShape.ts";
import { PlanDraft } from "./Consultation/PlanDraft.ts";

/**
 * Names one request to the Planner: the stream and position of the event that
 * caused it, such as `DailyDecision/i100:2026-11-09:3`. Policies run at least
 * once, so a request is sent again with the same id, and Planning applies one
 * it has already accepted only once and answers it the same way.
 */
export const PlannerRequestId = Schema.String.pipe(
  Schema.check(Schema.isPattern(/^[A-Za-z]+\/[A-Za-z0-9:_-]{1,200}:[1-9][0-9]*$/)),
  Schema.brand("PlannerRequestId"),
);
export type PlannerRequestId = typeof PlannerRequestId.Type;

/** The request caused by one event, the same each time a policy handles it. */
export const requestFor = (envelope: { readonly stream: string; readonly seq: number }): PlannerRequestId =>
  PlannerRequestId.make(`${envelope.stream}:${envelope.seq}`);

/**
 * The Planning model, in the coach's language. The coach proposes; Planning
 * decides with its own rules and answers whether it accepted.
 */
export class Planner extends Domain.ExternalSystem("Planner", {
  concretizeSession: {
    args: { requestId: PlannerRequestId, planId: PlanId, day: Day, workout: Workout, evidence: EvidenceSnapshot },
    success: { answer: PlanAnswer },
  },
  reviseWeek: {
    args: { requestId: PlannerRequestId, planId: PlanId, limits: Schema.Array(DayLimit) },
    success: { answer: PlanAnswer },
  },
  createPlan: {
    args: { requestId: PlannerRequestId, planId: PlanId, draft: PlanDraft },
    success: { answer: PlanAnswer },
  },
}) {}
