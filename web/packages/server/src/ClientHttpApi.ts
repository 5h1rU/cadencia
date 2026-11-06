import { AthleteCoachApi } from "@cadencia/coach/AthleteCoachApi.api";
import { CoachDeviceApi } from "@cadencia/coach/CoachDeviceApi.api";
import { AthletePlanningApi } from "@cadencia/planning/AthletePlanningApi.api";
import * as DomainHttp from "@alchemy.run/domain/Http";
import * as HttpApi from "effect/http-api/HttpApi";
import * as HttpApiBuilder from "effect/http-api/HttpApiBuilder";
import * as Etag from "effect/http/Etag";
import * as HttpPlatform from "effect/http/HttpPlatform";
import * as HttpRouter from "effect/http/HttpRouter";
import * as FileSystem from "effect/FileSystem";
import * as Layer from "effect/Layer";
import * as Path from "effect/Path";
import { layerOverCoach, layerOverPlanning } from "./Hosting.ts";

const Device = DomainHttp.toHttpApi(CoachDeviceApi);
const Coach = DomainHttp.toHttpApi(AthleteCoachApi);
const Planning = DomainHttp.toHttpApi(AthletePlanningApi);

/**
 * The domain as plain HTTP JSON, with an OpenAPI document at `/v1/openapi.json`,
 * for clients that are not Effect: Cadencia iOS. Every call goes through the
 * same Apis, middleware and rules as the web's; iOS is one more client.
 */
export const ClientApi = HttpApi.make("Cadencia")
  .add(Device.group.prefix("/v1"))
  .add(Coach.group.prefix("/v1"))
  .add(Planning.group.prefix("/v1"));

export const clientHttp = HttpApiBuilder.layer(ClientApi, { openapiPath: "/v1/openapi.json" }).pipe(
  Layer.provide([
    layerOverCoach(Device.layerFor(ClientApi)),
    layerOverCoach(Coach.layerFor(ClientApi)),
    layerOverPlanning(Planning.layerFor(ClientApi)),
  ]),
  // A Worker has no file system; the API never serves files.
  Layer.provide([HttpPlatform.layer.pipe(Layer.provide([FileSystem.layerNoop({}), Path.layer])), Etag.layer]),
  HttpRouter.toHttpEffect,
);
