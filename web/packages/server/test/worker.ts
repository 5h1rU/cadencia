import { Calendar } from "@cadencia/planning/Plan/Calendar.external";
import * as Domain from "@alchemy.run/domain";
import type { RuntimeContext } from "alchemy/RuntimeContext";
import * as ConfigProvider from "effect/ConfigProvider";
import * as Effect from "effect/Effect";
import * as HttpServerRequest from "effect/http/HttpServerRequest";
import * as Layer from "effect/Layer";
import type * as Scope from "effect/Scope";
import { MemoryConnections } from "../src/Connections.ts";
import { PlanningHosted } from "../src/Hosting.ts";
import { webHttp } from "../src/WebHttp.ts";
import { SessionKeyTest } from "./session.ts";

/** The public origin the app Worker forwards requests from. */
export const ORIGIN = "https://cadencia.test";

/** The secret the Intervals OAuth app sends with its webhooks. */
export const WEBHOOK_SECRET = "a-webhook-secret";

/** The Worker's configuration: the Intervals OAuth app. */
const WorkerConfig = ConfigProvider.layer(
  ConfigProvider.fromUnknown({
    INTERVALS_CLIENT_ID: "cadencia-test",
    INTERVALS_CLIENT_SECRET: "a-client-secret",
    INTERVALS_WEBHOOK_SECRET: WEBHOOK_SECRET,
  }),
);

/** A calendar that accepts everything, in place of Intervals.icu. */
export const AcceptingCalendar = Calendar.toLayer(
  Effect.succeed({
    publishSession: () => Effect.succeed({ published: true }),
    withdrawSession: () => Effect.succeed({ withdrawn: true }),
  }),
);

/** What the Worker's HttpApi is built over, in memory: Planning, the Intervals connections and the session key. */
export const WorkerWorld = PlanningHosted.pipe(
  Layer.provideMerge(Layer.mergeAll(MemoryConnections, SessionKeyTest)),
  Layer.provide(Layer.mergeAll(AcceptingCalendar, Domain.InMemory)),
);

/**
 * Run a test in the Worker's world. `Connections` asks for the platform's
 * RuntimeContext; the in-memory store never reads it, so the tests run without one.
 */
export const inWorker = <A, E>(effect: Effect.Effect<A, E, Scope.Scope | RuntimeContext | Layer.Success<typeof WorkerWorld>>) =>
  (effect as Effect.Effect<A, E, Scope.Scope | Layer.Success<typeof WorkerWorld>>).pipe(
    Effect.scoped,
    Effect.provide(WorkerWorld),
  );

/** Send a request for `path` through the Worker's HttpApi, as the app Worker forwards it (keeping the Host). */
export const serve = (path: string, init?: RequestInit) =>
  Effect.gen(function* () {
    const http = yield* webHttp;
    const headers = new globalThis.Headers(init?.headers);
    headers.set("host", new URL(ORIGIN).host);
    return yield* http.pipe(
      Effect.provideService(
        HttpServerRequest.HttpServerRequest,
        HttpServerRequest.fromWeb(new Request(`${ORIGIN}${path}`, { ...init, headers })),
      ),
    );
  }).pipe(Effect.scoped, Effect.provide(WorkerConfig));
