import { AthleteId } from "@cadencia/identity/Athlete.id";
import { PlanId } from "@cadencia/kernel/Plan.id";
import * as Domain from "@alchemy.run/domain";
import * as Schema from "effect/Schema";
import { isOlder } from "../Plan/PlanCreation.ts";
import { ActivePlanSwitched, PlanSuperseded, SwitchActivePlan } from "./SwitchActivePlan.command.ts";

/**
 * Which of an athlete's plans is the active one. An athlete has at most one:
 * the newest plan replaces the previous one, which is then retired. Plans'
 * creations can arrive out of order, so a plan older than the active one is
 * retired instead of activated.
 */
export class ActivePlan extends Domain.Aggregate("ActivePlan", {
  id: AthleteId,
  state: Schema.Struct({
    planId: Schema.NullOr(PlanId),
    /** When the active plan was created; unknown for one activated before it was kept. */
    createdAt: Schema.optional(Schema.NullOr(Schema.DateTimeUtc)),
  }),
  initial: { planId: null, createdAt: null },
  commands: [SwitchActivePlan],
  decide: {
    SwitchActivePlan: (state, cmd) => {
      if (state.planId === cmd.planId) return [];
      const active = state.planId !== null && state.createdAt != null ? { planId: state.planId, createdAt: state.createdAt } : null;
      if (active !== null && isOlder(cmd, active)) return [new PlanSuperseded({ planId: cmd.planId, by: active.planId })];
      return [new ActivePlanSwitched({ planId: cmd.planId, previous: state.planId, createdAt: cmd.createdAt })];
    },
  },
  evolve: {
    ActivePlanSwitched: (_, e) => ({ planId: e.planId, createdAt: e.createdAt ?? null }),
    PlanSuperseded: (s) => s,
  },
}) {}
