import { AthleteCoachApi } from "@cadencia/coach/AthleteCoachApi.api";
import { AthleteId } from "@cadencia/identity/Athlete.id";
import { Day } from "@cadencia/kernel/Calendar/Day";
import { AthletePlanningApi } from "@cadencia/planning/AthletePlanningApi.api";
import * as Domain from "@alchemy.run/domain";
import * as Effect from "effect/Effect";
import * as FetchHttpClient from "effect/http/FetchHttpClient";
import * as Layer from "effect/Layer";
import * as Socket from "effect/socket/Socket";
import { Runtime } from "foldkit";
import { Flags, init, Model, subscriptions, update, view } from "./Cadencia.ts";

/** Who is signed in: the session cookie is HttpOnly, so ask the server. */
const signedIn = Effect.tryPromise(async () => {
  const response = await fetch("/api/session", { credentials: "same-origin" });
  if (!response.ok) return null;
  const body = (await response.json()) as { readonly athleteId: string };
  return AthleteId.make(body.athleteId);
}).pipe(Effect.orElseSucceed(() => null));

/** Today in the athlete's own time zone, as `YYYY-MM-DD`. */
const today = Effect.sync(() => Day.make(new Date().toLocaleDateString("sv-SE")));

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
