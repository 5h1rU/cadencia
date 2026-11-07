import * as HttpApi from "effect/http-api/HttpApi";
import * as OpenApi from "effect/http-api/OpenApi";
import { IntervalsWebhookGroup } from "../Intervals/IntervalsWebhook.ts";
import { AuthGroup } from "./AuthGroup.ts";
import { IntervalsGroup } from "./IntervalsGroup.ts";
import { RequestValidation } from "./RequestValidation.middleware.ts";
import { SessionGroup } from "./SessionGroup.ts";

/**
 * What the Worker serves over plain HTTP besides the domain's own Apis: the
 * session, signing in with Intervals.icu, the athlete's Intervals.icu data for
 * the web, and Intervals' webhooks. It is the server's, as Alchemy's layout
 * keeps non-domain HTTP: the web app calls it with the domain's value schemas.
 * Its OpenAPI document is at `/api/openapi.json`.
 */
export const WebApi = HttpApi.make("CadenciaWeb")
  .add(SessionGroup.prefix("/api"))
  .add(IntervalsGroup.prefix("/api"))
  .add(AuthGroup.prefix("/auth"))
  .add(IntervalsWebhookGroup)
  .middleware(RequestValidation)
  .annotate(OpenApi.Title, "Cadencia web")
  .annotate(OpenApi.Description, "The session, signing in with Intervals.icu, the athlete's Intervals.icu data, and Intervals' webhooks.");
