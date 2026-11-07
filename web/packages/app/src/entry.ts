import { AthleteCoachApi } from "@cadencia/coach/AthleteCoachApi.api";
import { AthleteId } from "@cadencia/identity/Athlete.id";
import { AthletePlanningApi } from "@cadencia/planning/AthletePlanningApi.api";
import * as Domain from "@alchemy.run/domain";
import * as Effect from "effect/Effect";
import * as FetchHttpClient from "effect/http/FetchHttpClient";
import * as HttpClient from "effect/http/HttpClient";
import * as HttpClientResponse from "effect/http/HttpClientResponse";
import * as Schema from "effect/Schema";
import * as Layer from "effect/Layer";
import * as Socket from "effect/socket/Socket";
import { Http, Runtime } from "foldkit";
import { Flags, init, localDayOf, Model, subscriptions, update, view } from "./Cadencia.ts";

/** Who is signed in: the session cookie is HttpOnly, so ask the server. Anything unexpected is signed out. */
const signedIn = HttpClient.get("/api/session").pipe(
  Effect.flatMap(HttpClientResponse.filterStatusOk),
  Effect.flatMap(HttpClientResponse.schemaBodyJson(Schema.Struct({ athleteId: AthleteId }))),
  Effect.map(({ athleteId }) => athleteId),
  Effect.orElseSucceed(() => null),
  Effect.provide(Http.layer),
);

/** Today in the athlete's own time zone; the app moves it on at local midnight. */
const today = Effect.sync(() => localDayOf(new Date()));

/**
 * Both Apis for the life of the app, on this origin, so the browser sends the
 * session cookie with every call and every watch.
 */
const Clients = Layer.mergeAll(
  AthletePlanningApi.layerClient.pipe(Layer.provide(Domain.protocolWebSocket(`${location.origin}/api/planning`))),
  AthleteCoachApi.layerClient.pipe(Layer.provide(Domain.protocolWebSocket(`${location.origin}/api/coach`))),
).pipe(Layer.provide([Socket.layerWebSocketConstructorGlobal, FetchHttpClient.layer]));

Runtime.run(
  Runtime.makeApplication({
    Model,
    Flags,
    init,
    update,
    view,
    subscriptions,
    resources: Clients,
    container: document.getElementById("root"),
  }),
  {
    flags: Effect.gen(function* () {
      return {
        athleteId: yield* signedIn,
        today: yield* today,
        // Names this page's commands, so each is unique even across reloads.
        session: crypto.randomUUID(),
      };
    }),
  },
);
