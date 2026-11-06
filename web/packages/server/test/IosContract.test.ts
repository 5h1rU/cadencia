import { athlete } from "@cadencia/kernel/Actor";
import { Calendar } from "@cadencia/planning/Plan/Calendar.external";
import * as Domain from "@alchemy.run/domain";
import { describe, expect, it } from "@effect/vitest";
import * as Effect from "effect/Effect";
import * as FileSystem from "effect/FileSystem";
import * as ServerRequest from "effect/http/HttpServerRequest";
import * as HttpServerResponse from "effect/http/HttpServerResponse";
import * as Layer from "effect/Layer";
import * as Path from "effect/Path";
import type * as Scope from "effect/Scope";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { clientHttp } from "../src/ClientHttpApi.ts";
import { CoachHosted, PlanningHosted } from "../src/Hosting.ts";
import { PlanningPlanner } from "../src/Planner.ts";
import { SessionLive, signSession } from "../src/Session.ts";
import { SessionKeyTest } from "./session.ts";

/**
 * The contract with Cadencia iOS, checked from both sides without a deployment. iOS's tests write the
 * exact command bodies its client sends (`backend-requests.json`); this replays them through the HTTP
 * API iOS calls and records what the views answer (`backend-views.json`), which iOS's tests decode.
 * After changing either side: `CADENCIA_UPDATE_FIXTURES=1 swift test --filter BackendContractTests` in
 * CadenciaCore, then `CADENCIA_UPDATE_FIXTURES=1 npx pnpm@10 --filter @cadencia/server test` here.
 */
const fixtures = new URL("../../../../CadenciaCore/Tests/CadenciaCoreTests/Fixtures/", import.meta.url);
const requestsFile = new URL("backend-requests.json", fixtures);
const viewsFile = new URL("backend-views.json", fixtures);

interface Recorded {
  readonly order: ReadonlyArray<string>;
  readonly commands: Record<string, { readonly command: string; readonly body: unknown }>;
}
const recorded = JSON.parse(readFileSync(requestsFile, "utf8")) as Recorded;

const FakeCalendar = Calendar.toLayer(
  Effect.succeed({
    publishSession: () => Effect.succeed({ eventId: 1 }),
    withdrawSession: () => Effect.succeed({ withdrawn: true }),
  }),
);

const World = SessionLive.pipe(
  Layer.provideMerge(SessionKeyTest),
  Layer.provideMerge(CoachHosted),
  Layer.provideMerge(PlanningPlanner),
  Layer.provideMerge(PlanningHosted),
  Layer.provide(Layer.mergeAll(FakeCalendar, Domain.InMemory)),
);

// The HTTP API never serves files; the Worker gives it the same no-op file system.
const Platform = Layer.mergeAll(FileSystem.layerNoop({}), Path.layer);

const inCadencia = <A, E>(
  effect: Effect.Effect<A, E, Scope.Scope | Layer.Success<typeof World> | Layer.Success<typeof Platform>>,
) => effect.pipe(Effect.scoped, Effect.provide(World), Effect.provide(Platform));

/** Times are when the test ran; the fixture keeps one fixed instant. */
const normalized = (view: unknown): unknown =>
  JSON.parse(JSON.stringify(view), (key, value) => (key === "at" && typeof value === "string" ? "2026-11-10T07:00:00.000Z" : value));

describe("Cadencia iOS contract", () => {
  it.live("the commands iOS sends are accepted, and the views answer as iOS decodes them", () =>
    inCadencia(
      Effect.gen(function* () {
        const http = yield* clientHttp;
        const token = yield* signSession(athlete("i100"));
        const call = (method: "GET" | "POST", path: string, body?: unknown) =>
          Effect.gen(function* () {
            const request = new Request(`http://localhost${path}`, {
              method,
              headers: { authorization: `Bearer ${token}`, "content-type": "application/json", accept: "application/json" },
              ...(body === undefined ? {} : { body: JSON.stringify(body) }),
            });
            const response = yield* http.pipe(
              Effect.provideService(ServerRequest.HttpServerRequest, ServerRequest.fromWeb(request)),
              Effect.scoped,
            );
            const web = HttpServerResponse.toWeb(response);
            const text = yield* Effect.promise(() => web.text());
            return { status: web.status, json: text ? (JSON.parse(text) as unknown) : null };
          });

        const sent: Array<string> = [];
        const send = (label: string) =>
          Effect.gen(function* () {
            const entry = recorded.commands[label];
            expect(entry, `iOS recorded no command "${label}"`).toBeDefined();
            const answer = yield* call("POST", `/v1/${entry!.command}`, entry!.body);
            expect(answer.status, `${label}: ${JSON.stringify(answer.json)}`).toBe(200);
            sent.push(label);
          });
        const read = (view: string, key: string) =>
          call("GET", `/v1/${view}/${key}`).pipe(
            Effect.tap((answer) => Effect.sync(() => expect(answer.status, `${view}/${key}`).toBe(200))),
            Effect.map((answer) => answer.json as Record<string, any> | null),
          );
        const until = (view: string, key: string, done: (state: Record<string, any>) => boolean) =>
          Effect.gen(function* () {
            for (let i = 0; i < 1000; i++) {
              const state = yield* read(view, key);
              if (state !== null && done(state)) return state;
              yield* Effect.sleep("10 millis");
            }
            throw new Error(`${view}/${key} never reached the expected state`);
          });

        const views: Record<string, unknown> = {};
        yield* send("startConsultation");
        yield* send("recordCoachQuestion");
        yield* send("answerQuestion");
        yield* send("recordDraft");
        yield* send("acceptDraft");
        views.consultation = yield* until("ConsultationView", "i100:c1", (c) => c.stage === "created");
        yield* until("CurrentPlan", "i100", (p) => p.status === "active");

        yield* send("recordDailyDecisionRefused");
        views.decisionRefused = yield* until("TodayDecision", "i100:2026-11-10", (d) => d.status === "refused");
        yield* send("recordDailyDecisionAccepted");
        views.decisionAccepted = yield* until("TodayDecision", "i100:2026-11-10", (d) => d.status === "accepted");

        yield* send("sendMessage");
        yield* send("recordCoachReplyWithIntent");
        yield* send("acceptIntent");
        yield* until("ConversationThread", "i100:2026-11", (t) => t.messages[1]?.intentStatus === "applied");
        yield* send("sendMessageThanks");
        yield* send("recordCoachReplyWithoutIntent");
        yield* send("sendMessageAway");
        yield* send("recordCoachReplyAway");
        yield* send("dismissIntent");
        views.thread = yield* until("ConversationThread", "i100:2026-11", (t) => t.messages[5]?.intentStatus === "dismissed");
        views.plan = yield* until(
          "CurrentPlan",
          "i100",
          (p) =>
            p.sessions.every((s: { status: string }) => s.status === "published") &&
            p.sessions.some((s: { day: string; targetMinutes: number }) => s.day === "2026-11-12" && s.targetMinutes === 40),
        );

        yield* send("recordProfileAttempt");
        yield* send("recordProfile");
        views.profile = yield* until("RiderProfileCard", "i100", (c) => c.report !== null);

        yield* send("recordDayRequirement");
        yield* send("moveSession");
        // Once moved, the session is published again on its new day.
        views.planChanged = yield* until("CurrentPlan", "i100", (p) =>
          p.sessions.some(
            (s: { sessionId: string; day: string; status: string }) =>
              s.sessionId === "2026-11-12" && s.day === "2026-11-13" && s.status === "published",
          ),
        );
        yield* send("retirePlan");
        views.planRetired = yield* until("CurrentPlan", "i100", (p) => p.status === "retired");

        // Every command iOS recorded was replayed, in its order.
        expect(sent).toEqual(recorded.order);

        const answered = normalized(views);
        if (process.env.CADENCIA_UPDATE_FIXTURES || !existsSync(viewsFile)) {
          writeFileSync(viewsFile, `${JSON.stringify(answered, null, 2)}\n`);
        }
        expect(answered).toEqual(JSON.parse(readFileSync(viewsFile, "utf8")));
      }),
    ),
  );
});
