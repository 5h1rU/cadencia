import { ownerOf } from "@cadencia/identity/Athlete.id";
import * as Domain from "@alchemy.run/domain";
import * as Effect from "effect/Effect";
import { PlanCreated } from "../Plan/CreatePlan.command.ts";
import { Plan } from "../Plan/Plan.aggregate.ts";
import { ActivePlan } from "./ActivePlan.aggregate.ts";
import { SwitchActivePlan } from "./SwitchActivePlan.command.ts";

/** Whenever a plan is created, it becomes the athlete's active plan. */
export class PlanActivation extends Domain.Policy("PlanActivation", {
  from: Plan,
  on: [PlanCreated],
}) {}

export const PlanActivationLive = PlanActivation.toLayer(
  Effect.gen(function* () {
    const activePlans = yield* ActivePlan;
    return Effect.fn(function* ({ source }) {
      yield* activePlans.send(ownerOf(source.id), new SwitchActivePlan({ planId: source.id }));
    });
  }),
);
