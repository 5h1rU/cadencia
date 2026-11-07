import * as HttpApi from "effect/http-api/HttpApi";
import * as OpenApi from "effect/http-api/OpenApi";
import { AuthGroup } from "./AuthGroup.ts";
import { IntervalsGroup } from "./IntervalsGroup.ts";
import { RequestValidation } from "./RequestValidation.middleware.ts";
import { SessionGroup } from "./SessionGroup.ts";

/**
 * What the Worker serves the web app over plain HTTP, besides the domain's own
 * Apis: the session, signing in, and the athlete's Intervals.icu data. The
 * server implements it; the app calls it through `HttpApiClient`. Its OpenAPI
 * document is at `/api/openapi.json`.
 */
export const WebApi = HttpApi.make("CadenciaWeb")
  .add(SessionGroup.prefix("/api"))
  .add(IntervalsGroup.prefix("/api"))
  .add(AuthGroup.prefix("/auth"))
  .middleware(RequestValidation)
  .annotate(OpenApi.Title, "Cadencia web")
  .annotate(OpenApi.Description, "The session, signing in with Intervals.icu, and the athlete's Intervals.icu data.");
