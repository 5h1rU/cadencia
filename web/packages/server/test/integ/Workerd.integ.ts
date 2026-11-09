import { AthleteCoachApi } from "@cadencia/coach/AthleteCoachApi.api";
import { consultationIdFor } from "@cadencia/coach/Consultation/Consultation.id";
import { type Actor, athlete } from "@cadencia/identity/Actor";
import { AthleteId } from "@cadencia/identity/Athlete.id";
import { sessionClient } from "@cadencia/identity/Authenticated.middleware";
import { Day } from "@cadencia/kernel/Calendar/Day";
import { EntityKey } from "@cadencia/kernel/EntityKey";
import { planIdFor } from "@cadencia/kernel/Plan.id";
import { AthletePlanningApi } from "@cadencia/planning/AthletePlanningApi.api";
import { SessionId } from "@cadencia/planning/Plan/Session.id";
import * as Cloudflare from "@alchemy.run/cloudflare";
import * as Domain from "@alchemy.run/domain";
import * as Test from "@alchemy.run/test/Vitest";
import { expect } from "@effect/vitest";
import * as Alchemy from "alchemy";
import * as Effect from "effect/Effect";
import * as FetchHttpClient from "effect/http/FetchHttpClient";
import * as HttpClient from "effect/http/HttpClient";
import * as HttpClientRequest from "effect/http/HttpClientRequest";
import * as Layer from "effect/Layer";
import * as Queue from "effect/Queue";
import * as Schedule from "effect/Schedule";
import * as Schema from "effect/Schema";
import * as Socket from "effect/socket/Socket";
import * as Stream from "effect/Stream";
import { existsSync, readdirSync, rmSync } from "node:fs";
import { join } from "node:path";
import { signSession } from "../../src/Session.ts";
import { SessionKeyTest } from "../session.ts";
import Stack from "./TestStack.ts";

/*
 * Cadencia's API Worker on local workerd, for what the in-memory tests can't
 * show: the Durable Objects that hold each aggregate, view and policy, D1,
 * the Worker's routing, and a view watched over a WebSocket. Nothing leaves
 * this machine: `dev` runs every resource in workerd, the Calendar is a fake
 * and no route here calls Intervals.icu.
 */

// `ALCHEMY_TEST_DEV` overrides `dev` below in both directions; turned off, this would deploy to Cloudflare.
if (/^(false|0|no|off)$/i.test(process.env.ALCHEMY_TEST_DEV ?? "")) {
  throw new Error("This test only runs on local workerd: unset ALCHEMY_TEST_DEV.");
}

const { test, beforeAll, afterAll, deploy, destroy } = Test.make({
  providers: Cloudflare.providers(),
  state: Alchemy.localState(),
  dev: true,
  // Local resources need no Cloudflare account: the process that runs them gets no credentials.
  sidecar: { omitEnv: ["CLOUDFLARE_"] },
});

/**
 * Alchemy 2.0.0-beta.85 destroys a local Worker without deleting what its
 * Durable Objects stored, and names the next one differently, so every run
 * would leave some 4 MB behind in `.alchemy/local`. This deletes it: the
 * directories start with the stack's name, which nothing else uses.
 */
const sweepLocalObjects = Effect.sync(() => {
  const local = join(".alchemy", "local");
  if (!existsSync(local)) return;
  for (const name of readdirSync(local)) {
    if (name.startsWith("cadenciaintegration-")) rmSync(join(local, name), { recursive: true, force: true });
  }
});

// Destroyed first, so a run that was cut short leaves nothing for the next one to trip over.
const stack = beforeAll(destroy(Stack).pipe(Effect.andThen(sweepLocalObjects), Effect.andThen(deploy(Stack))), {
  timeout: 300_000,
});
afterAll.skipIf(!!process.env.NO_DESTROY)(destroy(Stack).pipe(Effect.andThen(sweepLocalObjects)));

const anaId = AthleteId.make("i100");
const ana = athlete("i100");
const bob = athlete("i200");
const planId = planIdFor(anaId, EntityKey.make("0b6f5a2e-1c3d-4e5f-8a9b-0c1d2e3f4a5b"));
const consultation = consultationIdFor(anaId, EntityKey.make("7c9e6679-7425-40de-944b-e07fc1f90ae7"));
const day = Schema.decodeUnknownSync(Day);

/** The plan the AI drafted on iOS, as iOS sends it. */
const draft = {
  title: "Base block",
  goal: "endurance",
  objective: "Build an aerobic base",
  rationale: "Six weeks of easy volume.",
  startDay: "2026-11-09",
  endDay: "2026-12-20",
  phases: [{ focus: "base", startWeek: 1, endWeek: 6, summary: "Aerobic base" }],
  longRideWeekday: 7,
  event: null,
  sessions: [
    { day: "2026-11-10", kind: "endurance", title: "Easy endurance", targetMinutes: 60, purpose: "Aerobic base" },
    { day: "2026-11-12", kind: "endurance", title: "Easy endurance", targetMinutes: 60, purpose: "Aerobic base" },
  ],
};

/** A session token for `actor`, signed with the key the test Worker verifies with. */
const tokenFor = (actor: Actor) => signSession(actor).pipe(Effect.provide(SessionKeyTest));

/** The Worker's address, once workerd serves it. */
const worker = Effect.gen(function* () {
  const { url } = yield* stack;
  const base = url.replace(/\/+$/, "");
  // Local resources live on this machine; anything else would be a real deployment.
  expect(["localhost", "127.0.0.1"]).toContain(new URL(base).hostname);
  yield* Test.getWhenReady(`${base}/api/openapi.json`);
  return base;
});

/** Every WebSocket the test opened, by its address. */
const sockets: Array<string> = [];

/**
 * How a client that is not a browser reaches one of the domain's Apis:
 * calls over HTTP and each watch a WebSocket, both carrying the session as
 * `Authorization` (Node's `WebSocket` accepts headers; a browser sends the cookie).
 */
const connectedAs = (address: string, token: string) =>
  Layer.mergeAll(Domain.protocolWebSocket(address), sessionClient(token)).pipe(
    Layer.provide(
      Layer.mergeAll(
        FetchHttpClient.layer,
        Layer.succeed(
          Socket.WebSocketConstructor,
          (url, protocols) => {
            sockets.push(url);
            return new WebSocket(url, { protocols, headers: { authorization: `Bearer ${token}` } } as unknown as Array<string>);
          },
        ),
      ),
    ),
  );

/** The web's Planning Api, at the route the Worker serves it on. */
const planningAs = (base: string, actor: Actor) =>
  Effect.flatMap(tokenFor(actor), (token) =>
    AthletePlanningApi.client.pipe(Effect.provide(connectedAs(`${base}/api/planning`, token))),
  );

/** The web's Coach Api, at the route the Worker serves it on. */
const coachAs = (base: string, actor: Actor) =>
  Effect.flatMap(tokenFor(actor), (token) =>
    AthleteCoachApi.client.pipe(Effect.provide(connectedAs(`${base}/api/coach`, token))),
  );

/** One request to the Worker's plain HTTP routes, signed in as `actor` or not at all. */
const request = (actor: Actor | null, call: HttpClientRequest.HttpClientRequest) =>
  Effect.gen(function* () {
    const signed = actor === null ? call : HttpClientRequest.bearerToken(call, yield* tokenFor(actor));
    const response = yield* HttpClient.execute(signed);
    const text = yield* response.text;
    return { status: response.status, json: text ? (JSON.parse(text) as unknown) : null };
  });

/** A command as Cadencia iOS sends it: plain JSON to `/v1`. */
const send = (base: string, command: string, target: string, input: unknown) =>
  request(ana, HttpClientRequest.post(`${base}/v1/${command}`).pipe(HttpClientRequest.bodyJsonUnsafe({ target, input }))).pipe(
    Effect.tap((answer) => Effect.sync(() => expect(answer.status, `${command}: ${JSON.stringify(answer.json)}`).toBe(200))),
  );

test(
  "a consultation accepted over /v1 becomes a published plan on a WebSocket watch, which then delivers a moved session",
  Effect.gen(function* () {
    const base = yield* worker;
    const web = yield* planningAs(base, ana);

    // One watch for the whole test: everything below arrives on the same subscription.
    type Plan = NonNullable<Effect.Success<ReturnType<typeof web.CurrentPlan.get>>>;
    const plans = yield* Queue.unbounded<Plan | null, unknown>();
    yield* web.CurrentPlan.watch(anaId).pipe(
      Stream.runForEach(({ state }) => Queue.offer(plans, state)),
      Effect.catchCause((cause) => Queue.failCause(plans, cause)),
      Effect.forkScoped,
    );
    const delivered = (done: (plan: Plan) => boolean) =>
      Queue.take(plans).pipe(
        Effect.repeat({ until: (plan) => plan !== null && done(plan) }),
        Effect.map((plan) => plan!),
        Effect.timeout("60 seconds"),
      );
    // The watch is open before anything is written: the athlete has no plan yet.
    expect(yield* Queue.take(plans).pipe(Effect.timeout("60 seconds"))).toBeNull();

    // iOS records the AI's draft and the athlete accepts it; the Coach's policy asks Planning for the plan.
    yield* send(base, "StartConsultation", consultation, {});
    yield* send(base, "RecordDraft", consultation, { draft, model: "gpt-5.5", interpretedOn: "ios" });
    yield* send(base, "AcceptDraft", consultation, { planId, draftRevision: 1 });

    // Planning activates it, and its policy publishes every session to the calendar.
    const active = yield* delivered((plan) => plan.sessions.every((s) => s.status === "published"));
    expect(active).toMatchObject({ status: "active", title: "Base block" });
    expect(active.sessions.map((s) => s.day)).toEqual(["2026-11-10", "2026-11-12"]);

    // The Coach saw Planning's answer too, read through its own route.
    const coach = yield* coachAs(base, ana);
    const created = yield* coach.ConsultationView.get(consultation).pipe(
      Effect.repeat({ until: (view) => view?.stage === "created", schedule: Schedule.spaced("100 millis"), times: 100 }),
    );
    expect(created?.stage).toBe("created");

    // A change the web makes reaches the open watch: moved, then published again on its new day.
    yield* web.MoveSession(planId, { sessionId: SessionId.make("2026-11-12"), toDay: day("2026-11-13") });
    const moved = yield* delivered((plan) =>
      plan.sessions.some((s) => s.sessionId === "2026-11-12" && s.day === "2026-11-13" && s.status === "published"),
    );
    expect(moved.sessions.map((s) => s.day)).toEqual(["2026-11-10", "2026-11-13"]);

    // All of it came through one WebSocket to the Worker's Planning route.
    expect(sockets.filter((url) => url.includes("CurrentPlan.watch"))).toEqual([
      expect.stringContaining(`${base.replace(/^http/, "ws")}/api/planning?`),
    ]);
  }).pipe(Effect.scoped),
  { timeout: 180_000 },
);

test(
  "another athlete can't read the plan",
  Effect.gen(function* () {
    const base = yield* worker;
    const stranger = yield* planningAs(base, bob);
    expect((yield* stranger.CurrentPlan.get(anaId).pipe(Effect.flip))._tag).toBe("NotYours");
    const answer = yield* request(bob, HttpClientRequest.get(`${base}/v1/CurrentPlan/${anaId}`));
    expect(answer.status).toBe(403);
  }).pipe(Effect.scoped),
  { timeout: 60_000 },
);

test(
  "the Worker's own routes know the session, and read the athlete's Intervals connection from D1",
  Effect.gen(function* () {
    const base = yield* worker;
    expect((yield* request(null, HttpClientRequest.get(`${base}/api/session`))).status).toBe(401);
    expect(yield* request(ana, HttpClientRequest.get(`${base}/api/session`))).toEqual({ status: 200, json: { athleteId: "i100" } });
    // The migrated table answers that nobody connected Intervals; without it the query would fail as a 500.
    const measures = yield* request(ana, HttpClientRequest.get(`${base}/api/intervals/athlete`));
    expect(measures).toMatchObject({ status: 409, json: { _tag: "IntervalsNotConnected" } });
  }).pipe(Effect.scoped),
  { timeout: 60_000 },
);
