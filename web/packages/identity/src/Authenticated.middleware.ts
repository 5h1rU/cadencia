import * as Headers from "effect/http/Headers";
import * as RpcMiddleware from "effect/rpc/RpcMiddleware";
import * as Schema from "effect/Schema";
import { CurrentActor } from "./CurrentActor.context.ts";

/** The request has no valid session. */
export class Unauthorized extends Schema.TaggedError<Unauthorized>()("Unauthorized", {}, { httpApiStatus: 401 }) {}

/** The cookie that carries an athlete's session in a browser. */
export const SESSION_COOKIE = "cadencia_session";

/**
 * Guards a command or a read: the request must come from a signed-in athlete,
 * who is provided as the {@link CurrentActor}. Browsers send the session
 * cookie; Cadencia iOS and other clients send `Authorization: Bearer`. In the
 * domain "session" means a training session: this is named for what it requires.
 */
export class Authenticated extends RpcMiddleware.Service<Authenticated, { provides: CurrentActor }>()(
  "Cadencia/Authenticated",
  { error: Unauthorized },
) {}

/** Client side, for clients that are not browsers: send this token with every call. */
export const sessionClient = (token: string) =>
  RpcMiddleware.layerClient(Authenticated, ({ request, next }) =>
    next({ ...request, headers: Headers.set(request.headers, "authorization", `Bearer ${token}`) }),
  );
