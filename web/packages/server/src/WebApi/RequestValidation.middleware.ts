import * as HttpApiError from "effect/http-api/HttpApiError";
import * as HttpApiMiddleware from "effect/http-api/HttpApiMiddleware";

/**
 * A request whose path, query or body doesn't match its endpoint's schemas is
 * the client's mistake: it answers 400, not a server error.
 */
export class RequestValidation extends HttpApiMiddleware.Service<RequestValidation>()("Cadencia/RequestValidation", {
  error: HttpApiError.BadRequest,
}) {}
