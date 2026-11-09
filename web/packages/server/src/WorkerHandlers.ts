import { AthleteCoachApi } from "@cadencia/coach/AthleteCoachApi.api";
import { AthletePlanningApi } from "@cadencia/planning/AthletePlanningApi.api";
import * as Cloudflare from "@alchemy.run/cloudflare";
import * as DomainCloudflare from "@alchemy.run/cloudflare/Domain";
import type * as ExternalSystem from "@alchemy.run/domain/ExternalSystem";
import * as Effect from "effect/Effect";
import { HttpServerRequest } from "effect/http/HttpServerRequest";
import * as Layer from "effect/Layer";
import { clientHttp } from "./ClientHttpApi.ts";
import { D1Connections } from "./Connections.ts";
import { CoachHosted, overCoach, overPlanning, PlanningHosted } from "./Hosting.ts";
import { PlanningPlanner } from "./Planner.ts";
import { type SessionKey, SessionLive } from "./Session.ts";
import { webHttp } from "./WebHttp.ts";

/**
 * Both models on Durable Objects in the EU, the Coach's Planner answered by
 * Planning in process, and the athletes' Intervals tokens in D1, around the
 * two parts that differ between the deployed Worker and the one the
 * integration test runs: the key that signs sessions, and the calendar
 * sessions are published to. Swap `layerDurableObjects` for `Domain.InMemory`
 * and nothing else changes.
 */
export const hostedOnCloudflare = <KeyError, KeyRequires, CalendarError, CalendarRequires>(
  sessionKey: Layer.Layer<SessionKey, KeyError, KeyRequires>,
  calendar: Layer.Layer<ExternalSystem.ExternalSystemKey<"Calendar">, CalendarError, CalendarRequires>,
) =>
  SessionLive.pipe(
    Layer.provideMerge(sessionKey),
    Layer.provideMerge(CoachHosted),
    Layer.provideMerge(PlanningPlanner),
    Layer.provideMerge(PlanningHosted),
    Layer.provideMerge(calendar),
    Layer.provideMerge(D1Connections),
    Layer.provide(
      Layer.mergeAll(
        DomainCloudflare.layerDurableObjects({ jurisdiction: "eu" }),
        Cloudflare.D1.QueryDatabaseBinding,
        // Workers Traces: the Domain spans of commands, policies and external calls, and failed
        // policy runs that happen outside any request.
        Cloudflare.Telemetry(),
      ),
    ),
  );

/**
 * What the Worker answers: the domain's own Apis for the web app; the domain
 * over HTTP for iOS; and the Worker's HttpApi (session, signing in, Intervals
 * reads, Intervals' webhooks) for everything else.
 */
export const workerHandlers = Effect.gen(function* () {
  const planningApi = yield* overPlanning(AthletePlanningApi);
  const coachApi = yield* overCoach(AthleteCoachApi);
  const ios = yield* clientHttp;
  const web = yield* webHttp;

  return {
    fetch: Effect.gen(function* () {
      const { pathname } = new URL((yield* HttpServerRequest).url, "http://localhost");
      if (pathname.startsWith("/api/planning")) return yield* planningApi.fetch;
      if (pathname.startsWith("/api/coach")) return yield* coachApi.fetch;
      if (pathname.startsWith("/v1/")) return yield* ios;
      return yield* web;
    }),
  };
});
