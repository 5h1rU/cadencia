import * as Domain from "@alchemy.run/domain";
import * as Effect from "effect/Effect";
import { Planner } from "../Planner.external.ts";
import { DraftAccepted, RecordPlanCreation } from "./Consult.commands.ts";
import { Consultation } from "./Consultation.aggregate.ts";

/** Whenever the athlete accepts a draft, ask Planning to create the plan, and record its answer. */
export class PlanFromConsultation extends Domain.Policy("PlanFromConsultation", {
  from: Consultation,
  on: [DraftAccepted],
}) {}

export const PlanFromConsultationLive = PlanFromConsultation.toLayer(
  Effect.gen(function* () {
    const planner = yield* Planner;
    const consultations = yield* Consultation;
    return Effect.fn(function* ({ source, event }) {
      const answer = yield* planner.createPlan({ planId: event.planId, draft: event.draft });
      yield* consultations.send(source, new RecordPlanCreation(answer));
    });
  }),
);
