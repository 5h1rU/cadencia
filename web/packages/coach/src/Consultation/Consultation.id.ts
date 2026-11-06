import * as Schema from "effect/Schema";

/** One plan consultation of one athlete: `<athleteId>:<consultationKey>`. */
export const ConsultationId = Schema.String.pipe(
  Schema.check(Schema.isPattern(/^[^:]+:[^:]+$/)),
  Schema.brand("ConsultationId"),
);
export type ConsultationId = typeof ConsultationId.Type;
