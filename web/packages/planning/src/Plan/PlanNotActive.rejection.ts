import * as Domain from "@alchemy.run/domain";

/** The plan is not active: never created, or retired. */
export class PlanNotActive extends Domain.Rejection("PlanNotActive", {}, { httpApiStatus: 409 }) {}
