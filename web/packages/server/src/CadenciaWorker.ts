import { AthleteCoachApi } from "@cadencia/coach/AthleteCoachApi.api";
import { AthletePlanningApi } from "@cadencia/planning/AthletePlanningApi.api";
import * as Cloudflare from "@alchemy.run/cloudflare";
import * as DomainCloudflare from "@alchemy.run/cloudflare/Domain";
import * as Effect from "effect/Effect";
import { HttpServerRequest } from "effect/http/HttpServerRequest";
import * as Layer from "effect/Layer";
import { Stage } from "alchemy/Stage";
import { clientHttp } from "./ClientHttpApi.ts";
import { D1Connections } from "./Connections.ts";
import { CoachHosted, overCoach, overPlanning, PlanningHosted } from "./Hosting.ts";
import { IntervalsCalendar } from "./Intervals/IntervalsCalendar.ts";
import { PlanningPlanner } from "./Planner.ts";
import { SessionKeyLive, SessionLive } from "./Session.ts";
import { webHttp } from "./WebHttp.ts";

/**
 * The Workers' names in prod. Intervals.icu has the app's origin registered as
 * the OAuth callback and the privacy policy's address, so prod keeps the names
 * it was first deployed under whatever Alchemy's state holds.
 */
export const PROD_WORKER_NAMES = {
  api: "cadencia-cadenciaworker-prod-fr37k62cb36d666m",
  app: "cadencia-cadenciaapp-prod-6ki44jvdsgk3fzku",
} as const;

/**
 * Both models on Durable Objects in the EU, the Coach's Planner answered by
 * Planning in process, the Calendar by Intervals.icu, and the athletes'
 * Intervals tokens in D1. Swap `layerDurableObjects` for `Domain.InMemory`
 * and nothing else changes.
 */
const CadenciaLive = SessionLive.pipe(
  Layer.provideMerge(SessionKeyLive),
  Layer.provideMerge(CoachHosted),
  Layer.provideMerge(PlanningPlanner),
  Layer.provideMerge(PlanningHosted),
  Layer.provideMerge(IntervalsCalendar),
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

export default class CadenciaWorker extends Cloudflare.Worker<CadenciaWorker>()(
  "CadenciaWorker",
  Effect.gen(function* () {
    // prod keeps the name it was first deployed under, so its URL doesn't depend on Alchemy's state.
    const stage = yield* Stage;
    return {
      main: import.meta.url,
      ...(stage === "prod" ? { name: PROD_WORKER_NAMES.api } : {}),
      // Cloudflare.Telemetry needs a compatibility date with `tracing.startActiveSpan`.
      compatibility: { date: "2026-08-25" },
    };
  }),
  Effect.gen(function* () {
    const planningApi = yield* overPlanning(AthletePlanningApi);
    const coachApi = yield* overCoach(AthleteCoachApi);
    const ios = yield* clientHttp;
    const web = yield* webHttp;

    return {
      // The domain's own Apis for the web app; the domain over HTTP for iOS; and the Worker's
      // HttpApi (session, signing in, Intervals reads, Intervals' webhooks) for everything else.
      fetch: Effect.gen(function* () {
        const { pathname } = new URL((yield* HttpServerRequest).url, "http://localhost");
        if (pathname.startsWith("/api/planning")) return yield* planningApi.fetch;
        if (pathname.startsWith("/api/coach")) return yield* coachApi.fetch;
        if (pathname.startsWith("/v1/")) return yield* ios;
        return yield* web;
      }),
    };
  }).pipe(Effect.provide(CadenciaLive)),
) {}
