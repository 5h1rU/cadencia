import type { AthleteId } from "@cadencia/identity/Athlete.id";
import { SESSION_COOKIE, Unauthorized } from "@cadencia/identity/Session.middleware";
import * as Context from "effect/Context";
import * as HttpApiMiddleware from "effect/http-api/HttpApiMiddleware";
import * as HttpApiSecurity from "effect/http-api/HttpApiSecurity";
import * as OpenApi from "effect/http-api/OpenApi";

/** The athlete a request is signed in as. */
export class SignedInAthlete extends Context.Service<SignedInAthlete, AthleteId>()("Cadencia/SignedInAthlete") {}

/**
 * A signed-in athlete: browsers carry the session in an HttpOnly cookie,
 * other clients send it as `Authorization: Bearer`. Anything else, or a
 * session that isn't an athlete's, is Unauthorized.
 */
export class Authentication extends HttpApiMiddleware.Service<Authentication, { provides: SignedInAthlete }>()(
  "Cadencia/Authentication",
  {
    error: Unauthorized,
    security: {
      cookie: HttpApiSecurity.apiKey({ key: SESSION_COOKIE, in: "cookie" }).pipe(
        HttpApiSecurity.annotate(OpenApi.Description, "The session cookie the web gets when it signs in."),
      ),
      bearer: HttpApiSecurity.bearer.pipe(
        HttpApiSecurity.annotate(OpenApi.Description, "A session token, as Cadencia iOS gets it from /auth/exchange."),
      ),
    },
  },
) {}
