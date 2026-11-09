import * as Cloudflare from "@alchemy.run/cloudflare";
import * as Effect from "effect/Effect";
import { Stage } from "alchemy/Stage";
import { IntervalsCalendar } from "./Intervals/IntervalsCalendar.ts";
import { SessionKeyLive } from "./Session.ts";
import { hostedOnCloudflare, workerHandlers } from "./WorkerHandlers.ts";

/**
 * The Workers' names in prod. Intervals.icu has the app's origin registered as
 * the OAuth callback and the privacy policy's address, so prod keeps the names
 * it was first deployed under whatever Alchemy's state holds.
 */
export const PROD_WORKER_NAMES = {
  api: "cadencia-cadenciaworker-prod-fr37k62cb36d666m",
  app: "cadencia-cadenciaapp-prod-6ki44jvdsgk3fzku",
} as const;

/** Sessions signed with the stage's own key, and the Calendar answered by Intervals.icu. */
const CadenciaLive = hostedOnCloudflare(SessionKeyLive, IntervalsCalendar);

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
      // Workers Issues groups recurring failures (exceptions, 5xx answers, `console.error`) in the
      // dashboard. An explicit `observability` replaces Alchemy's default whole, so the default
      // logs are written out again; `traces` stays unset, which is what lets
      // `Cloudflare.Telemetry()` (in `hostedOnCloudflare`) fill it in.
      observability: {
        enabled: true,
        logs: { enabled: true, invocationLogs: true },
        issues: { enabled: true },
      },
    };
  }),
  workerHandlers.pipe(Effect.provide(CadenciaLive)),
) {}
