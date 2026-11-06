import * as Domain from "@alchemy.run/domain";
import { SessionId } from "./Session.id.ts";

/** No session with that id in the plan. */
export class SessionNotFound extends Domain.Rejection("SessionNotFound", { sessionId: SessionId }, { httpApiStatus: 404 }) {}
