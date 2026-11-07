import { EvidenceSnapshot } from "@cadencia/athlete/Evidence";
import { AthleteId } from "@cadencia/identity/Athlete.id";
import { Day } from "@cadencia/kernel/Calendar/Day";
import { PlanId } from "@cadencia/kernel/Plan.id";
import { DayLimit } from "@cadencia/kernel/Training/DayLimit";
import { Workout } from "@cadencia/kernel/Training/Workout";
import * as Domain from "@alchemy.run/domain";
import * as Schema from "effect/Schema";
import { PlanDraft } from "./Consultation/PlanDraft.ts";
import { PlanAnswer } from "./PlanAnswer.ts";

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
 * The Planning model, in the coach's language. The coach proposes on behalf of
 * `athleteId`, the athlete whose decision, intent or consultation it is;
 * Planning decides with its own rules, as that athlete, and answers whether it
 * accepted.
 */
export class Planner extends Domain.ExternalSystem("Planner", {
  concretizeSession: {
    args: {
      requestId: PlannerRequestId,
      athleteId: AthleteId,
      planId: PlanId,
      day: Day,
      workout: Workout,
      evidence: EvidenceSnapshot,
    },
    success: { answer: PlanAnswer },
  },
  reviseWeek: {
    args: {
      requestId: PlannerRequestId,
      athleteId: AthleteId,
      planId: PlanId,
      limits: Schema.Array(DayLimit),
      today: Day,
    },
    success: { answer: PlanAnswer },
  },
  createPlan: {
    args: { requestId: PlannerRequestId, athleteId: AthleteId, planId: PlanId, draft: PlanDraft },
    success: { answer: PlanAnswer },
  },
}) {}
