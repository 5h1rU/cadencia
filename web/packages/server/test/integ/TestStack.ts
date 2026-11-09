import * as Cloudflare from "@alchemy.run/cloudflare";
import * as Alchemy from "alchemy";
import * as Effect from "effect/Effect";
import CadenciaTestWorker from "./CadenciaTestWorker.ts";

/**
 * The API Worker alone, for the integration test: no web app, whose local
 * port is fixed, and its state on this machine, never in Cloudflare.
 */
export default Alchemy.Stack(
  "CadenciaIntegration",
  { providers: Cloudflare.providers(), state: Alchemy.localState() },
  Effect.gen(function* () {
    const api = yield* CadenciaTestWorker;
    return { url: api.url.as<string>() };
  }),
);
