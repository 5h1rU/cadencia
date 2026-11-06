import * as Domain from "@alchemy.run/domain";

/** The caller is not the athlete this belongs to. */
export class NotYours extends Domain.Rejection("NotYours", {}, { httpApiStatus: 403 }) {}
