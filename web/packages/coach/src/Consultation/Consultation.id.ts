import type { AthleteId } from "@cadencia/identity/Athlete.id";
import type { EntityKey } from "@cadencia/kernel/EntityKey";
import * as Schema from "effect/Schema";

/** One plan consultation of one athlete: `<athleteId>:<uuid>`. */
export const ConsultationId = Schema.String.pipe(
  Schema.check(Schema.isPattern(/^i[1-9][0-9]*:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/)),
  Schema.brand("ConsultationId"),
);
export type ConsultationId = typeof ConsultationId.Type;

export const consultationIdFor = (athleteId: AthleteId, key: EntityKey): ConsultationId =>
  ConsultationId.make(`${athleteId}:${key}`);
