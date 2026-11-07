import { IosCoachApi } from "@cadencia/coach/IosCoachApi.api";
import { IosPlanningApi } from "@cadencia/planning/IosPlanningApi.api";
import { RequestValidation } from "@cadencia/web-api/RequestValidation.middleware";
import * as DomainHttp from "@alchemy.run/domain/Http";
import * as Effect from "effect/Effect";
import * as HttpApi from "effect/http-api/HttpApi";
import * as HttpApiBuilder from "effect/http-api/HttpApiBuilder";
import * as HttpRouter from "effect/http/HttpRouter";
import * as Layer from "effect/Layer";
import { layerOverCoach, layerOverPlanning } from "./Hosting.ts";
import { RequestValidationLive, respondToFailures, WorkerHttpPlatform } from "./WorkerHttpPlatform.ts";

const Coach = DomainHttp.toHttpApi(IosCoachApi);
const Planning = DomainHttp.toHttpApi(IosPlanningApi);

/**
 * The domain as plain HTTP JSON, with an OpenAPI document at `/v1/openapi.json`,
 * for clients that are not Effect: Cadencia iOS. It publishes only iOS's own
 * Apis, so the rest of the domain can change without reaching the App Store
 * build. Every call goes through the same middleware and rules as the web's.
 */
export const ClientApi = HttpApi.make("Cadencia")
  .add(Coach.group.prefix("/v1"))
  .add(Planning.group.prefix("/v1"))
  .middleware(RequestValidation);

export const clientHttp = HttpApiBuilder.layer(ClientApi, { openapiPath: "/v1/openapi.json" }).pipe(
  Layer.provide([
    layerOverCoach(Coach.layerFor(ClientApi)),
    layerOverPlanning(Planning.layerFor(ClientApi)),
  ]),
  Layer.provide([RequestValidationLive, WorkerHttpPlatform]),
  HttpRouter.toHttpEffect,
  Effect.map(respondToFailures),
);
