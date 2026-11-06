import { ATHLETE_ID_PATTERN, type AthleteId } from "@cadencia/identity/Athlete.id";
import * as Schema from "effect/Schema";
import { type EntityKey, UUID_PATTERN } from "./EntityKey.ts";

/**
 * One training plan of one athlete: `<athleteId>:<uuid>`. Planning owns plans;
 * the Coach names them when it drafts one and when it asks about a day.
 */
export const PlanId = Schema.String.pipe(
  Schema.check(Schema.isPattern(new RegExp(`^${ATHLETE_ID_PATTERN}:${UUID_PATTERN}$`))),
  Schema.brand("PlanId"),
);
export type PlanId = typeof PlanId.Type;

export const planIdFor = (athleteId: AthleteId, key: EntityKey): PlanId => PlanId.make(`${athleteId}:${key}`);
