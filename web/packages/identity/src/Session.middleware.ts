import * as Headers from "effect/http/Headers";
import * as RpcMiddleware from "effect/rpc/RpcMiddleware";
import * as Schema from "effect/Schema";
import { CurrentActor } from "./CurrentActor.context.ts";

/** The request has no valid session. */
export class Unauthorized extends Schema.TaggedError<Unauthorized>()("Unauthorized", {}, { httpApiStatus: 401 }) {}

/** The cookie that carries an athlete's session in a browser. */
export const SESSION_COOKIE = "cadencia_session";

/**
 * Authenticates a request and provides the athlete making it as the
 * {@link CurrentActor}. Browsers send the session cookie; Cadencia iOS and
 * other clients send `Authorization: Bearer`.
 */
export class Session extends RpcMiddleware.Service<Session, { provides: CurrentActor }>()(
  "Cadencia/Session",
  { error: Unauthorized },
) {}

/** Client side, for clients that are not browsers: send this token with every call. */
export const sessionClient = (token: string) =>
  RpcMiddleware.layerClient(Session, ({ request, next }) =>
    next({ ...request, headers: Headers.set(request.headers, "authorization", `Bearer ${token}`) }),
  );
