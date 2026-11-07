import { AthleteId } from "@cadencia/identity/Athlete.id";
import { PlanId } from "@cadencia/kernel/Plan.id";
import * as Domain from "@alchemy.run/domain";
import * as Schema from "effect/Schema";

export class ActivePlanSwitched extends Domain.Event("ActivePlanSwitched", {
  planId: PlanId,
  /** The plan it replaces, which must be retired. */
  previous: Schema.NullOr(PlanId),
}) {}

/** Make a newly created plan the athlete's active one. Sent by `PlanReplacement`; it never rejects. */
export class SwitchActivePlan extends Domain.Command("SwitchActivePlan", {
  target: AthleteId,
  input: { planId: PlanId },
  events: [ActivePlanSwitched],
}) {}
