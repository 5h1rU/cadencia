import { athlete } from "@cadencia/identity/Actor";
import { AthleteId } from "@cadencia/identity/Athlete.id";
import { SESSION_COOKIE } from "@cadencia/identity/Authenticated.middleware";
import { describe, expect, it } from "@effect/vitest";
import * as Duration from "effect/Duration";
import * as Effect from "effect/Effect";
import * as Base64Url from "effect/encoding/Base64Url";
import * as Fiber from "effect/Fiber";
import * as Cookies from "effect/http/Cookies";
import * as Headers from "effect/http/Headers";
import * as HttpServerResponse from "effect/http/HttpServerResponse";
import * as Option from "effect/Option";
import * as Redacted from "effect/Redacted";
import * as Result from "effect/Result";
import * as TestClock from "effect/testing/TestClock";
import { afterEach, vi } from "vitest";
import { Connections } from "../src/Connections.ts";
import { INTERVALS_DEADLINE } from "../src/Intervals/IntervalsHttp.ts";
import { actorOf, signHandoff, signSession } from "../src/Session.ts";
import { neverAnswers } from "./intervals.ts";
import { inWorker, ORIGIN, serve } from "./worker.ts";

const FLOW_COOKIE = "cadencia_oauth";

/** The OAuth app the Worker is configured with, and the callback it registers for this origin. */
const config = { clientId: "cadencia-test", redirectUri: `${ORIGIN}/auth/intervals/callback` };

const intervalsAthlete = AthleteId.make("i393051");

const location = (response: HttpServerResponse.HttpServerResponse) => response.headers["location"];

const cookie = (response: HttpServerResponse.HttpServerResponse, name: string) =>
  Option.getOrThrow(Cookies.getValue(response.cookies, name));

const sha256 = (text: string) =>
  Effect.promise(async () =>
    Base64Url.encode(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text)))),
  );

/** Intervals' token endpoint, in place of the real one. */
interface TokenCall {
  readonly url: string;
  readonly body: URLSearchParams;
}
const stubIntervals = (status: number, answer: unknown) => {
  const calls: Array<TokenCall> = [];
  vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
    calls.push({ url: String(input), body: new URLSearchParams(String(init?.body)) });
    return new Response(JSON.stringify(answer), { status, headers: { "content-type": "application/json" } });
  });
  return calls;
};

const granted = {
  access_token: "intervals-access-token",
  scope: "ACTIVITY:WRITE,CALENDAR:WRITE,NOT:A_SCOPE",
  athlete: { id: intervalsAthlete },
};

afterEach(() => {
  vi.restoreAllMocks();
});

/** Start a sign-in and return the flow cookie, its decoded contents and the authorize URL. */
const start = (query = "") =>
  Effect.gen(function* () {
    const response = yield* serve(`/auth/intervals/start${query}`);
    expect(response.status).toBe(302);
    const flowCookie = cookie(response, FLOW_COOKIE);
    const flowJson = Base64Url.decodeString(flowCookie);
    if (Result.isFailure(flowJson)) throw new Error("The flow cookie is not base64url");
    const flow = JSON.parse(flowJson.success) as { state: string; verifier: string; client: string };
    return { flowCookie, flow, authorize: new URL(location(response)!) };
  });

describe("GET /auth/intervals/start", () => {
  it.effect("sets the flow cookie and sends the athlete to Intervals with its state and an S256 challenge", () =>
    Effect.gen(function* () {
      const { flow, authorize } = yield* start();
      expect(authorize.origin + authorize.pathname).toBe("https://intervals.icu/oauth/authorize");
      expect(authorize.searchParams.get("client_id")).toBe(config.clientId);
      expect(authorize.searchParams.get("redirect_uri")).toBe(config.redirectUri);
      expect(authorize.searchParams.get("scope")).toBe(
        "ACTIVITY:WRITE,WELLNESS:WRITE,CALENDAR:WRITE,SETTINGS:WRITE,CHATS:WRITE",
      );
      expect(authorize.searchParams.get("state")).toBe(flow.state);
      expect(authorize.searchParams.get("code_challenge_method")).toBe("S256");
      expect(authorize.searchParams.get("code_challenge")).toBe(yield* sha256(flow.verifier));
      expect(flow.verifier).not.toBe(flow.state);
      expect(flow.client).toBe("web");
    }).pipe(inWorker),
  );

  it.effect("remembers that an iOS sign-in returns to iOS", () =>
    Effect.gen(function* () {
      const { flow } = yield* start("?client=ios");
      expect(flow.client).toBe("ios");
    }).pipe(inWorker),
  );
});

describe("GET /auth/intervals/callback", () => {
  it.effect("exchanges the code, keeps the athlete's token and signs the web in with a cookie", () =>
    inWorker(
      Effect.gen(function* () {
        const calls = stubIntervals(200, granted);
        const { flowCookie, flow } = yield* start();
        const response = yield* serve(`/auth/intervals/callback?code=the-code&state=${flow.state}`,
          { headers: { cookie: `${FLOW_COOKIE}=${flowCookie}` } },
        );

        expect(calls).toHaveLength(1);
        expect(calls[0]!.url).toBe("https://intervals.icu/api/oauth/token");
        expect(Object.fromEntries(calls[0]!.body)).toEqual({
          client_id: config.clientId,
          client_secret: "a-client-secret",
          code: "the-code",
          code_verifier: flow.verifier,
          redirect_uri: config.redirectUri,
        });

        const saved = yield* (yield* Connections).find(intervalsAthlete);
        expect(Option.isSome(saved)).toBe(true);
        const connection = Option.getOrThrow(saved);
        expect(Redacted.value(connection.token)).toBe("intervals-access-token");
        expect(connection.scopes).toEqual(["ACTIVITY:WRITE", "CALENDAR:WRITE"]);

        expect(response.status).toBe(302);
        expect(location(response)).toBe("/");
        expect(cookie(response, FLOW_COOKIE)).toBe("");
        const session = cookie(response, SESSION_COOKIE);
        expect(yield* actorOf(Headers.fromInput({ cookie: `${SESSION_COOKIE}=${session}` }))).toEqual(
          Option.some(athlete(intervalsAthlete)),
        );
      }),
    ),
  );

  it.effect("returns an iOS sign-in to the app with a handoff that exchanges for a session", () =>
    inWorker(
      Effect.gen(function* () {
        stubIntervals(200, granted);
        const { flowCookie, flow } = yield* start("?client=ios");
        const response = yield* serve(`/auth/intervals/callback?code=the-code&state=${flow.state}`,
          { headers: { cookie: `${FLOW_COOKIE}=${flowCookie}` } },
        );
        expect(response.status).toBe(302);
        expect(Option.isNone(Cookies.getValue(response.cookies, SESSION_COOKIE))).toBe(true);
        const back = new URL(location(response)!);
        expect(`${back.protocol}//${back.host}${back.pathname}`).toBe("cadencia://auth/callback");
        const handoff = back.searchParams.get("handoff")!;

        // The handoff is no session by itself.
        expect(yield* actorOf(Headers.fromInput({ authorization: `Bearer ${handoff}` }))).toEqual(Option.none());

        const exchanged = yield* serve("/auth/exchange", {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ handoff }),
        });
        expect(exchanged.status).toBe(200);
        const { token, intervalsAccessToken } = (yield* Effect.promise(() => HttpServerResponse.toWeb(exchanged).json())) as {
          token: string;
          intervalsAccessToken: string;
        };
        // The device gets the athlete's own Intervals token, for the calls it makes to Intervals itself.
        expect(intervalsAccessToken).toBe(granted.access_token);
        expect(yield* actorOf(Headers.fromInput({ authorization: `Bearer ${token}` }))).toEqual(
          Option.some(athlete(intervalsAthlete)),
        );
      }),
    ),
  );

  it.effect("refuses a callback whose state does not match the flow, or has none", () =>
    inWorker(
      Effect.gen(function* () {
        const calls = stubIntervals(200, granted);
        const { flowCookie, flow } = yield* start();
        const headers = { cookie: `${FLOW_COOKIE}=${flowCookie}` };

        const mismatched = yield* serve(`/auth/intervals/callback?code=the-code&state=${flow.state.slice(1)}x`,
          { headers },
        );
        expect(mismatched.status).toBe(400);

        const missingState = yield* serve("/auth/intervals/callback?code=the-code", { headers });
        expect(missingState.status).toBe(400);

        const missingFlow = yield* serve(`/auth/intervals/callback?code=the-code&state=${flow.state}`,
        );
        expect(missingFlow.status).toBe(400);

        const missingCode = yield* serve(`/auth/intervals/callback?state=${flow.state}`, {
          headers,
        });
        expect(missingCode.status).toBe(400);

        expect(calls).toHaveLength(0);
        expect(Option.isNone(yield* (yield* Connections).find(intervalsAthlete))).toBe(true);
      }),
    ),
  );

  it.effect("refuses the sign-in when Intervals does not accept the code", () =>
    inWorker(
      Effect.gen(function* () {
        const calls = stubIntervals(400, { error: "invalid_grant" });
        const { flowCookie, flow } = yield* start();
        const response = yield* serve(`/auth/intervals/callback?code=a-used-code&state=${flow.state}`,
          { headers: { cookie: `${FLOW_COOKIE}=${flowCookie}` } },
        );
        expect(calls).toHaveLength(1);
        expect(response.status).toBe(502);
        expect(Option.isNone(Cookies.getValue(response.cookies, SESSION_COOKIE))).toBe(true);
        expect(Option.isNone(yield* (yield* Connections).find(intervalsAthlete))).toBe(true);
      }),
    ),
  );

  it.effect("refuses the sign-in when Intervals doesn't answer the exchange within the deadline", () =>
    inWorker(
      Effect.gen(function* () {
        const requests = neverAnswers();
        const { flowCookie, flow } = yield* start();
        const answering = yield* Effect.forkChild(
          serve(`/auth/intervals/callback?code=a-code&state=${flow.state}`, { headers: { cookie: `${FLOW_COOKIE}=${flowCookie}` } }),
        );
        yield* TestClock.adjust(Duration.subtract(INTERVALS_DEADLINE, Duration.millis(1)));
        expect(requests.map((signal) => signal.aborted)).toEqual([false]);
        expect(answering.pollUnsafe()).toBeUndefined();
        yield* TestClock.adjust("1 millis");
        expect((yield* Fiber.join(answering)).status).toBe(502);
        expect(requests.map((signal) => signal.aborted)).toEqual([true]);
        expect(Option.isNone(yield* (yield* Connections).find(intervalsAthlete))).toBe(true);
      }),
    ),
  );
});

describe("POST /auth/exchange", () => {
  const exchange = (body: unknown, method = "POST") =>
    serve("/auth/exchange", {
      method,
      ...(method === "POST" ? { headers: { "content-type": "application/json" }, body: JSON.stringify(body) } : {}),
    });

  it.effect("turns only a live handoff of a connected athlete into a session", () =>
    Effect.gen(function* () {
      const ana = athlete("i100");
      // Not connected to Intervals any more: there is no token to hand over.
      expect((yield* exchange({ handoff: yield* signHandoff(ana) })).status).toBe(401);
      yield* (yield* Connections).save({ athleteId: AthleteId.make("i100"), token: Redacted.make("ana-token"), scopes: [] });
      expect((yield* exchange({ handoff: yield* signHandoff(ana) })).status).toBe(200);
      expect((yield* exchange({ handoff: yield* signSession(ana) })).status).toBe(401);
      expect((yield* exchange({ nothing: true })).status).toBe(400);
      // Only POST is served: anything else isn't a route.
      expect((yield* exchange(undefined, "GET")).status).toBe(404);
    }).pipe(inWorker),
  );
});
