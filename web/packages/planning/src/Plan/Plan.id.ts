import { AthleteId } from "@cadencia/kernel/Athlete.id";
import { ownerOf } from "@cadencia/kernel/owns";
import * as Schema from "effect/Schema";

/** One training plan of one athlete: `<athleteId>:<planKey>`. */
export const PlanId = Schema.String.pipe(
  Schema.check(Schema.isPattern(/^[^:]+:[^:]+$/)),
  Schema.brand("PlanId"),
);
export type PlanId = typeof PlanId.Type;

export const planIdFor = (athleteId: AthleteId, planKey: string): PlanId =>
  PlanId.make(`${athleteId}:${planKey}`);

export const athleteOfPlan = (planId: string): AthleteId => AthleteId.make(ownerOf(planId));
