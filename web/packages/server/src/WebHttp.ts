import { Unauthorized } from "@cadencia/identity/Session.middleware";
import { Day } from "@cadencia/kernel/Calendar/Day";
import { Authentication, SignedInAthlete } from "./WebApi/Authentication.middleware.ts";
import { IntervalsNotConnected } from "./WebApi/IntervalsGroup.ts";
import { WebApi } from "./WebApi/WebApi.ts";
import * as DateTime from "effect/DateTime";
import type { RuntimeContext } from "alchemy/RuntimeContext";
import * as Config from "effect/Config";
import * as Effect from "effect/Effect";
import * as HttpApiBuilder from "effect/http-api/HttpApiBuilder";
import * as HttpRouter from "effect/http/HttpRouter";
import type { HttpServerRequest } from "effect/http/HttpServerRequest";
import * as HttpServerResponse from "effect/http/HttpServerResponse";
import * as Layer from "effect/Layer";
import * as Option from "effect/Option";
import * as Redacted from "effect/Redacted";
import { Connections } from "./Connections.ts";
import { declareWellness, readActivities, readMeasures, readWellness } from "./Intervals/AthleteReads.ts";
import { PlanningInternals } from "./Hosting.ts";
import { syncAthlete } from "./Intervals/ChangeSync.ts";
import { exchangeHandoff, finishSignIn, startSignIn } from "./Intervals/IntervalsOAuth.ts";
import { calendarsChanged, sameSecret, WebhookRefused } from "./Intervals/IntervalsWebhook.ts";
import { SessionKey, verifySession, withoutSessionCookie } from "./Session.ts";
import { RequestValidationLive, respondToFailures, WorkerHttpPlatform } from "./WorkerHttpPlatform.ts";

/**
 * The platform gives every request its own `RuntimeContext` (the Worker's
 * bindings, such as D1), and HttpApi handlers run in the request's context,
 * so what needs it finds it there rather than when the handlers are built.
 */
const perRequest = <A, E>(effect: Effect.Effect<A, E, RuntimeContext>) => effect as unknown as Effect.Effect<A, E>;

/** A session cookie or Bearer token, as the athlete it was signed for. */
export const AuthenticationLive = Layer.effect(
  Authentication,
  Effect.gen(function* () {
    const key = yield* SessionKey;
    const authenticate: Authentication["Service"]["cookie"] = (httpEffect, { credential }) =>
      Effect.gen(function* () {
        const actor = yield* verifySession(Redacted.value(credential)).pipe(Effect.provideService(SessionKey, key));
        if (Option.isNone(actor) || actor.value._tag !== "Athlete") return yield* new Unauthorized();
        return yield* Effect.provideService(httpEffect, SignedInAthlete, actor.value.athleteId);
      });
    return { cookie: authenticate, bearer: authenticate };
  }),
);

export const SessionHttp = HttpApiBuilder.group(WebApi, "session", (handlers) =>
  handlers
    .handle("current", () => Effect.gen(function* () {
      return { athleteId: yield* SignedInAthlete };
    }))
    .handleRaw("signOut", () => Effect.succeed(HttpServerResponse.empty({ status: 204 }).pipe(withoutSessionCookie))),
);

/** The OAuth app registered in Intervals.icu; its callback is `<public origin>/auth/intervals/callback`. */
export const AuthHttp = HttpApiBuilder.group(
  WebApi,
  "auth",
  Effect.fnUntraced(function* (handlers) {
    const clientId = yield* Config.String("INTERVALS_CLIENT_ID");
    const clientSecret = yield* Config.Redacted("INTERVALS_CLIENT_SECRET");
    const connections = yield* Connections;
    const key = yield* SessionKey;
    // The request's URL carries only the path; the public origin is the app's host, which the app
    // Worker keeps when it forwards the request.
    const oauthFor = (request: HttpServerRequest) => {
      const host = request.headers["host"] ?? "localhost";
      const scheme = host.startsWith("localhost") || host.startsWith("127.0.0.1") ? "http" : "https";
      return { clientId, clientSecret, redirectUri: `${scheme}://${host}/auth/intervals/callback` };
    };
    const signedIn = <A, E>(effect: Effect.Effect<A, E, Connections | SessionKey | RuntimeContext>) =>
      perRequest(effect.pipe(Effect.provideService(Connections, connections), Effect.provideService(SessionKey, key)));
    return handlers
      .handleRaw("start", ({ query, request }) => startSignIn(oauthFor(request), query.client ?? "web"))
      .handleRaw("callback", ({ query, request }) => signedIn(finishSignIn(oauthFor(request), query, request.headers)))
      .handle("exchange", ({ payload }) => signedIn(exchangeHandoff(payload.handoff)));
  }),
);

export const IntervalsHttp = HttpApiBuilder.group(
  WebApi,
  "intervals",
  Effect.fnUntraced(function* (handlers) {
    const connections = yield* Connections;
    /** The signed-in athlete's Intervals token, or IntervalsNotConnected. */
    const asAthlete = <A, E>(call: (token: Redacted.Redacted<string>, athleteId: SignedInAthlete["Service"]) => Effect.Effect<A, E>) =>
      Effect.gen(function* () {
        const athleteId = yield* SignedInAthlete;
        const connection = yield* perRequest(connections.find(athleteId));
        if (Option.isNone(connection)) return yield* new IntervalsNotConnected();
        return yield* call(connection.value.token, athleteId);
      });
    return handlers
      .handle("wellness", ({ query }) => asAthlete((token, athleteId) => readWellness(token, athleteId, query)))
      .handle("activities", ({ query }) => asAthlete((token, athleteId) => readActivities(token, athleteId, query)))
      .handle("athlete", () => asAthlete(readMeasures))
      .handle("declareWellness", ({ params, payload }) =>
        asAthlete((token, athleteId) => declareWellness(token, athleteId, params.day, payload)),
      );
  }),
);

/**
 * Intervals.icu's webhooks. A changed calendar sends the athlete's sync, which
 * reads Intervals again and records what the athlete took over. It answers
 * after the sync, so Intervals retries a delivery whose sync failed.
 */
export const IntervalsWebhookHttp = HttpApiBuilder.group(
  WebApi,
  "intervalsWebhook",
  Effect.fnUntraced(function* (handlers) {
    const secret = yield* Config.Redacted("INTERVALS_WEBHOOK_SECRET");
    const connections = yield* Connections;
    const planning = yield* PlanningInternals;
    return handlers.handle("receive", ({ payload }) =>
      Effect.gen(function* () {
        if (!sameSecret(payload.secret, secret)) return yield* new WebhookRefused();
        const today = Day.make(DateTime.formatIsoDate(yield* DateTime.now));
        yield* Effect.forEach(calendarsChanged(payload.events), (athleteId) =>
          perRequest(
            syncAthlete(athleteId, today).pipe(
              Effect.provideService(Connections, connections),
              Effect.provideService(PlanningInternals, planning),
            ),
          ),
        );
        return { received: payload.events.length };
      }),
    );
  }),
);

/**
 * `WebApi` served from the Worker: the session, signing in, and the athlete's
 * Intervals.icu data, with its OpenAPI document at `/api/openapi.json`.
 * Requires the session key and the Intervals connections.
 */
export const webHttp = HttpApiBuilder.layer(WebApi, { openapiPath: "/api/openapi.json" }).pipe(
  Layer.provide([SessionHttp, AuthHttp, IntervalsHttp, IntervalsWebhookHttp]),
  Layer.provide([AuthenticationLive, RequestValidationLive]),
  Layer.provide(WorkerHttpPlatform),
  HttpRouter.toHttpEffect,
  Effect.map(respondToFailures),
);
