import * as Cloudflare from "@alchemy.run/cloudflare";
import CadenciaWorker, { PROD_WORKER_NAMES } from "@cadencia/server/CadenciaWorker";
import { Stage } from "alchemy/Stage";
import * as Alchemy from "alchemy";
import * as Effect from "effect/Effect";

/**
 * Cadencia on Cloudflare: the Worker that hosts both models, and the foldkit
 * web app. The app's Worker serves the build and forwards the API, the
 * sign-in and the HTTP API for iOS, so everything shares one origin and the
 * session cookie is first-party.
 */
export default Alchemy.Stack(
  "Cadencia",
  // State lives in Cloudflare, not on the machine that deployed: it holds the keys that sign
  // sessions and encrypt Intervals tokens, which every deploy must keep.
  { providers: Cloudflare.providers(), state: Cloudflare.state() },
  Effect.gen(function* () {
    const api = yield* CadenciaWorker;
    const stage = yield* Stage;
    const app = yield* Cloudflare.Website.Foldkit("CadenciaApp", {
      ...(stage === "prod" ? { name: PROD_WORKER_NAMES.app } : {}),
      rootDir: "packages/app",
      main: "src/worker.ts",
      env: { CADENCIA: api },
      assets: { runWorkerFirst: ["/api", "/api/*", "/auth/*", "/v1/*"] },
    });
    return { api: api.url.as<string>(), app: app.url.as<string>() };
  }),
);
