import { RequestValidation } from "./WebApi/RequestValidation.middleware.ts";
import * as Effect from "effect/Effect";
import * as HttpApiError from "effect/http-api/HttpApiError";
import * as HttpApiMiddleware from "effect/http-api/HttpApiMiddleware";
import * as Etag from "effect/http/Etag";
import * as HttpServerError from "effect/http/HttpServerError";
import type * as HttpServerResponse from "effect/http/HttpServerResponse";
import * as HttpPlatform from "effect/http/HttpPlatform";
import * as FileSystem from "effect/FileSystem";
import * as Layer from "effect/Layer";
import * as Path from "effect/Path";

/** Every request that doesn't match its endpoint's schemas answers 400 Bad Request. */
export const RequestValidationLive = HttpApiMiddleware.layerSchemaErrorTransform(RequestValidation, () =>
  Effect.fail(HttpApiError.BadRequest.singleton),
);

/** What an HttpApi needs to serve from a Worker. A Worker has no file system; no API here serves files. */
export const WorkerHttpPlatform = Layer.mergeAll(HttpPlatform.layer, Etag.layer).pipe(
  Layer.provideMerge(Layer.mergeAll(FileSystem.layerNoop({}), Path.layer)),
);

/**
 * Answer every failure the way an HTTP server would: a route that doesn't
 * exist is 404, a respondable error answers itself, anything else is 500 and
 * is logged. A Worker has no HTTP server around it to do this.
 */
export const respondToFailures = <E, R>(http: Effect.Effect<HttpServerResponse.HttpServerResponse, E, R>) =>
  http.pipe(
    Effect.catchCause((cause) =>
      HttpServerError.causeResponse(cause).pipe(
        Effect.tap(([response, failure]) =>
          response.status >= 500 ? Effect.logError("Request failed", failure) : Effect.void,
        ),
        Effect.map(([response]) => response),
      ),
    ),
  );
