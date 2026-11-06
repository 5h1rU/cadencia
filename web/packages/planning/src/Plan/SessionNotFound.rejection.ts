import * as Domain from "@alchemy.run/domain";
import * as Schema from "effect/Schema";

/** No session with that id in the plan. */
export class SessionNotFound extends Domain.Rejection(
  "SessionNotFound",
  { sessionId: Schema.String },
  { httpApiStatus: 404 },
) {}
