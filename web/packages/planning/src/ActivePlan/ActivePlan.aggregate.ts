import { AthleteId } from "@cadencia/identity/Athlete.id";
import { PlanId } from "@cadencia/kernel/Plan.id";
import * as Domain from "@alchemy.run/domain";
import * as Schema from "effect/Schema";
import { ActivePlanSwitched, SwitchActivePlan } from "./SwitchActivePlan.command.ts";

/**
 * Which of an athlete's plans is the active one. An athlete has at most one:
 * a new plan replaces the previous one, which is then retired.
 */
export class ActivePlan extends Domain.Aggregate("ActivePlan", {
  id: AthleteId,
  state: Schema.Struct({ planId: Schema.NullOr(PlanId) }),
  initial: { planId: null },
  commands: [SwitchActivePlan],
  decide: {
    SwitchActivePlan: (state, cmd) =>
      state.planId === cmd.planId ? [] : [new ActivePlanSwitched({ planId: cmd.planId, previous: state.planId })],
  },
  evolve: {
    ActivePlanSwitched: (_, e) => ({ planId: e.planId }),
  },
}) {}
