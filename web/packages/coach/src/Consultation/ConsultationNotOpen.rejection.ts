import * as Domain from "@alchemy.run/domain";

/** The consultation hasn't started, or it already ended. */
export class ConsultationNotOpen extends Domain.Rejection("ConsultationNotOpen", {}, { httpApiStatus: 409 }) {}
