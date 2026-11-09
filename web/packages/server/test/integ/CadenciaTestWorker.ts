import * as Cloudflare from "@alchemy.run/cloudflare";
import * as ConfigProvider from "effect/ConfigProvider";
import * as Effect from "effect/Effect";
import { hostedOnCloudflare, workerHandlers } from "../../src/WorkerHandlers.ts";
import { SessionKeyTest } from "../session.ts";
import { AcceptingCalendar } from "../worker.ts";

/**
 * A made-up Intervals OAuth app, read before whatever the machine's `.env`
 * holds: the test Worker never carries the real app's secrets.
 */
const MadeUpIntervalsApp = ConfigProvider.layerAdd(
  ConfigProvider.fromUnknown({
    INTERVALS_CLIENT_ID: "cadencia-test",
    INTERVALS_CLIENT_SECRET: "a-client-secret",
    INTERVALS_WEBHOOK_SECRET: "a-webhook-secret",
  }),
  { asPrimary: true },
);

/**
 * `CadenciaWorker` for the integration test: the same handlers over the same
 * Durable Objects and D1, with the two parts a test can't have. Signing in
 * only exists through Intervals.icu, so sessions are signed with a fixed key
 * the test knows; and the Calendar accepts everything instead of calling
 * Intervals.
 */
export default class CadenciaTestWorker extends Cloudflare.Worker<CadenciaTestWorker>()(
  "CadenciaTestWorker",
  Effect.succeed({ main: import.meta.url, compatibility: { date: "2026-08-25" } }),
  workerHandlers.pipe(
    Effect.provide(hostedOnCloudflare(SessionKeyTest, AcceptingCalendar)),
    Effect.provide(MadeUpIntervalsApp),
  ),
) {}
