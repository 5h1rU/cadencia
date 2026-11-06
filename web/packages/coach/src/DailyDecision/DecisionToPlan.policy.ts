import * as Domain from "@alchemy.run/domain";
import * as Effect from "effect/Effect";
import { Planner, requestFor } from "../Planner.external.ts";
import { DailyDecision } from "./DailyDecision.aggregate.ts";
import { DailyDecisionRecorded } from "./RecordDailyDecision.command.ts";
import { RecordPlanVerdict } from "./RecordPlanVerdict.command.ts";

/** Whenever the AI's decision for a day is recorded, ask the plan to accept it, and record the answer. */
export class DecisionToPlan extends Domain.Policy("DecisionToPlan", {
  from: DailyDecision,
  on: [DailyDecisionRecorded],
}) {}

export const DecisionToPlanLive = DecisionToPlan.toLayer(
  Effect.gen(function* () {
    const planner = yield* Planner;
    const decisions = yield* DailyDecision;
    return Effect.fn(function* ({ source, event, envelope }) {
      const { answer } = yield* planner.concretizeSession({
        requestId: requestFor(envelope),
        planId: event.planId,
        day: event.day,
        workout: event.workout,
        evidence: event.evidence,
      });
      yield* decisions.send(source, new RecordPlanVerdict({ attempt: event.attempt, answer }));
    });
  }),
);
