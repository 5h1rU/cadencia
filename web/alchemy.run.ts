import * as Cloudflare from "@alchemy.run/cloudflare";
import CadenciaWorker from "@cadencia/server/CadenciaWorker";
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
  { providers: Cloudflare.providers(), state: Alchemy.localState() },
  Effect.gen(function* () {
    const api = yield* CadenciaWorker;
    const app = yield* Cloudflare.Website.Foldkit("CadenciaApp", {
      rootDir: "packages/app",
      main: "src/worker.ts",
      env: { CADENCIA: api },
      assets: { runWorkerFirst: ["/api", "/api/*", "/auth/*", "/v1/*"] },
    });
    return { api: api.url.as<string>(), app: app.url.as<string>() };
  }),
);
