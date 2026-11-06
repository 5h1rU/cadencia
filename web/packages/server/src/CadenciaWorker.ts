import { AthleteCoachApi } from "@cadencia/coach/AthleteCoachApi.api";
import { Day } from "@cadencia/kernel/Day";
import { AthletePlanningApi } from "@cadencia/planning/AthletePlanningApi.api";
import * as Cloudflare from "@alchemy.run/cloudflare";
import * as DomainCloudflare from "@alchemy.run/cloudflare/Domain";
import * as Config from "effect/Config";
import * as Effect from "effect/Effect";
import { HttpServerRequest } from "effect/http/HttpServerRequest";
import * as HttpServerResponse from "effect/http/HttpServerResponse";
import * as Layer from "effect/Layer";
import { clientHttp } from "./ClientHttpApi.ts";
import { Connections, D1Connections } from "./Connections.ts";
import { athleteReadsRoute } from "./Intervals/AthleteReads.ts";
import { syncAll } from "./Intervals/ChangeSync.ts";
import { IntervalsCalendar } from "./Intervals/IntervalsCalendar.ts";
import { callbackRoute, exchangeRoute, startRoute } from "./Intervals/IntervalsOAuth.ts";
import { CoachHosted, overCoach, overPlanning, PlanningHosted } from "./Hosting.ts";
import { PlanningPlanner } from "./Planner.ts";
import { SessionKey, SessionKeyLive, SessionLive, sessionRoute } from "./Session.ts";

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
    ),
  ),
);

export default class CadenciaWorker extends Cloudflare.Worker<CadenciaWorker>()(
  "CadenciaWorker",
  { main: import.meta.url },
  Effect.gen(function* () {
    // The OAuth app registered in Intervals.icu for the web; its callback is
    // `<public origin>/auth/intervals/callback`.
    const intervalsClientId = yield* Config.String("INTERVALS_CLIENT_ID");
    const intervalsClientSecret = yield* Config.Redacted("INTERVALS_CLIENT_SECRET");
    const planningApi = yield* overPlanning(AthletePlanningApi);
    const coachApi = yield* overCoach(AthleteCoachApi);
    const sessionKey = yield* SessionKey;
    const connections = yield* Connections;
    const http = yield* clientHttp;

    // Every 30 minutes, notice what athletes changed in their Intervals calendar.
    yield* Cloudflare.Workers.cron("*/30 * * * *", () =>
      syncAll(Day.make(new Date().toISOString().slice(0, 10))),
    );

    return {
      fetch: Effect.gen(function* () {
        const request = yield* HttpServerRequest;
        const url = new URL(request.url, "http://localhost");
        const path = url.pathname;
        // The request's URL carries only the path; the public origin is the app's host,
        // which the app Worker keeps when it forwards the request.
        const host = request.headers["host"] ?? url.host;
        const origin = `${host.startsWith("localhost") || host.startsWith("127.0.0.1") ? "http" : "https"}://${host}`;
        const oauth = {
          clientId: intervalsClientId,
          clientSecret: intervalsClientSecret,
          redirectUri: `${origin}/auth/intervals/callback`,
        };
        const signedIn = <A, E, R>(effect: Effect.Effect<A, E, R>) =>
          effect.pipe(Effect.provideService(SessionKey, sessionKey), Effect.provideService(Connections, connections));
        if (path === "/api/session") return yield* signedIn(sessionRoute);
        if (path === "/auth/intervals/start") return yield* startRoute(oauth);
        if (path === "/auth/intervals/callback") return yield* signedIn(callbackRoute(oauth));
        if (path === "/auth/exchange") return yield* signedIn(exchangeRoute);
        if (path.startsWith("/api/intervals/")) return yield* signedIn(athleteReadsRoute);
        if (path.startsWith("/api/planning")) return yield* planningApi.fetch;
        if (path.startsWith("/api/coach")) return yield* coachApi.fetch;
        if (path.startsWith("/v1/")) return yield* http;
        return HttpServerResponse.text("Not Found", { status: 404 });
      }),
    };
  }).pipe(Effect.provide(CadenciaLive), Effect.provide(Cloudflare.Workers.CronEventSourceLive)),
) {}
