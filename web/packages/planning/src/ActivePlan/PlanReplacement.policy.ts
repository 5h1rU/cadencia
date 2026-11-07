import { system } from "@cadencia/identity/Actor";
import { CurrentActor } from "@cadencia/identity/CurrentActor.context";
import * as Domain from "@alchemy.run/domain";
import * as Effect from "effect/Effect";
import { Plan } from "../Plan/Plan.aggregate.ts";
import { RetirePlan } from "../Plan/RetirePlan.command.ts";
import { utcDayOf } from "../Plan/Today.ts";
import { ActivePlan } from "./ActivePlan.aggregate.ts";
import { ActivePlanSwitched } from "./SwitchActivePlan.command.ts";

/**
 * Whenever a plan replaces another, retire the one it replaced, so its
 * upcoming sessions leave the Intervals calendar. A policy has no local day:
 * it retires from the UTC date the switch happened.
 */
export class PlanReplacement extends Domain.Policy("PlanReplacement", {
  from: ActivePlan,
  on: [ActivePlanSwitched],
}) {}

export const PlanReplacementLive = PlanReplacement.toLayer(
  Effect.gen(function* () {
    const plans = yield* Plan;
    return Effect.fn(function* ({ event, envelope }) {
      if (event.previous === null) return;
      yield* plans.send(event.previous, new RetirePlan({ today: utcDayOf(envelope.at) })).pipe(
        Effect.provideService(CurrentActor, system("PlanReplacement")),
        // Already retired, or retired by the athlete in between: nothing left to do.
        Effect.catchTag("PlanNotActive", () => Effect.void),
        // A system actor may act on any plan and has no implausible day; neither can happen.
        Effect.catchTags({ NotYours: (e) => Effect.die(e), ImplausibleToday: (e) => Effect.die(e) }),
      );
    });
  }),
);
