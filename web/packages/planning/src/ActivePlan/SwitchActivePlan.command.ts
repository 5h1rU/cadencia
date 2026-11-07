import { AthleteId } from "@cadencia/identity/Athlete.id";
import { PlanId } from "@cadencia/kernel/Plan.id";
import * as Domain from "@alchemy.run/domain";
import * as Schema from "effect/Schema";

export class ActivePlanSwitched extends Domain.Event("ActivePlanSwitched", {
  planId: PlanId,
  /** The plan it replaces, which must be retired. */
  previous: Schema.NullOr(PlanId),
  /** When the plan was created. Switches recorded before it was kept don't have it. */
  createdAt: Schema.optional(Schema.DateTimeUtc),
}) {}

/** A plan whose creation arrived after a newer plan's: the newer one stays active, and this one must be retired. */
export class PlanSuperseded extends Domain.Event("PlanSuperseded", {
  planId: PlanId,
  /** The newer plan that stays active. */
  by: PlanId,
}) {}

/**
 * Make a newly created plan the athlete's active one, unless a newer plan
 * already is. Sent by `PlanActivation`; it never rejects.
 */
export class SwitchActivePlan extends Domain.Command("SwitchActivePlan", {
  target: AthleteId,
  input: { planId: PlanId, createdAt: Schema.DateTimeUtc },
  events: [ActivePlanSwitched, PlanSuperseded],
}) {}
