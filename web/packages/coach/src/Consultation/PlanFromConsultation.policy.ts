import * as Domain from "@alchemy.run/domain";
import * as Effect from "effect/Effect";
import { Planner, requestFor } from "../Planner.external.ts";
import { DraftAccepted } from "./AcceptDraft.command.ts";
import { Consultation } from "./Consultation.aggregate.ts";
import { RecordPlanCreation } from "./RecordPlanCreation.command.ts";

/** Whenever the athlete accepts a draft, ask Planning to create the plan, and record its answer. */
export class PlanFromConsultation extends Domain.Policy("PlanFromConsultation", {
  from: Consultation,
  on: [DraftAccepted],
}) {}

export const PlanFromConsultationLive = PlanFromConsultation.toLayer(
  Effect.gen(function* () {
    const planner = yield* Planner;
    const consultations = yield* Consultation;
    return Effect.fn(function* ({ source, event, envelope }) {
      const { answer } = yield* planner.createPlan({
        requestId: requestFor(envelope),
        planId: event.planId,
        draft: event.draft,
      });
      yield* consultations.send(source, new RecordPlanCreation({ answer }));
    });
  }),
);
