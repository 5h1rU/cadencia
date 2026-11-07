import * as Cloudflare from "@alchemy.run/cloudflare";
import CadenciaWorker, { PROD_WORKER_NAMES } from "@cadencia/server/CadenciaWorker";
import { Stage } from "alchemy/Stage";
import * as Alchemy from "alchemy";
import * as Effect from "effect/Effect";
import app from "./packages/app/package.json" with { type: "json" };

/**
 * The workspace packages the app bundles, from its own dependencies. Declared
 * rather than detected, so a package that no longer exists can't linger in the
 * stack's state and break the next deploy's change detection.
 */
const appWorkspaces = Object.keys(app.dependencies)
  .filter((name) => name.startsWith("@cadencia/"))
  .map((name) => ({ cwd: `../${name.slice("@cadencia/".length)}` }));

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
      memo: { workspaces: appWorkspaces },
      main: "src/worker.ts",
      env: { CADENCIA: api },
      // Every page (`/plan`, `/history`, …) is the app itself: a path that is no file serves index.html.
      assets: { runWorkerFirst: ["/api", "/api/*", "/auth/*", "/v1/*"], notFoundHandling: "single-page-application" },
      // Locally the sign-in returns to <app origin>/auth/intervals/callback, which Intervals must
      // know: keep the origin fixed rather than taking the next free port.
      dev: { port: 1338, strictPort: true },
    });
    return { api: api.url.as<string>(), app: app.url.as<string>() };
  }),
);
