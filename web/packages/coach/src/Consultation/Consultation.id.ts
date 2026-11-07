import { ATHLETE_ID_PATTERN, type AthleteId } from "@cadencia/identity/Athlete.id";
import { type EntityKey, UUID_PATTERN } from "@cadencia/kernel/EntityKey";
import * as Schema from "effect/Schema";

/** One plan consultation of one athlete: `<athleteId>:<uuid>`. */
export const ConsultationId = Schema.String.pipe(
  Schema.check(Schema.isPattern(new RegExp(`^${ATHLETE_ID_PATTERN}:${UUID_PATTERN}$`))),
  Schema.brand("ConsultationId"),
);
export type ConsultationId = typeof ConsultationId.Type;

export const consultationIdFor = (athleteId: AthleteId, key: EntityKey): ConsultationId =>
  ConsultationId.make(`${athleteId}:${key}`);
