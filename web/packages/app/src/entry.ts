import { AthleteCoachApi } from "@cadencia/coach/AthleteCoachApi.api";
import { AthletePlanningApi } from "@cadencia/planning/AthletePlanningApi.api";
import * as Domain from "@alchemy.run/domain";
import * as Effect from "effect/Effect";
import * as FetchHttpClient from "effect/http/FetchHttpClient";
import * as Layer from "effect/Layer";
import * as Socket from "effect/socket/Socket";
import { Http, Runtime } from "foldkit";
import { flags } from "./flags.ts";
import { init } from "./main.ts";
import { Message } from "./message.ts";
import { Flags, Model } from "./model.ts";
import { subscriptions } from "./subscription.ts";
import { viewTransition } from "./transition.ts";
import { update } from "./update.ts";
import { view } from "./view.ts";

/**
 * Both Apis for the life of the app, on this origin, so the browser sends the
 * session cookie with every call and every watch.
 */
export const Clients = Layer.mergeAll(
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
    // Each section is a page with its own URL: links move between them, and Back and reload keep the page.
    routing: {
      onUrlRequest: (request) => Message.ClickedLink({ request }),
      onUrlChange: (url) => Message.ChangedUrl({ url }),
    },
    container: document.getElementById("root"),
    // Moving between pages and the history arriving animate, where the browser can; nothing else does.
    viewTransition,
    // In development only. The Message schema lets the DevTools MCP dispatch Messages; the Model holds
    // no secrets (the session cookie is HttpOnly).
    devTools: { Message },
  }),
  {
    flags: flags.pipe(Effect.provide(Http.layer)),
  },
);
