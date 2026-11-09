import { describe, expect, it } from "@effect/vitest";
import * as Effect from "effect/Effect";
import * as Fiber from "effect/Fiber";
import * as HttpClient from "effect/http/HttpClient";
import * as HttpClientRequest from "effect/http/HttpClientRequest";
import * as HttpClientResponse from "effect/http/HttpClientResponse";
import * as TestClock from "effect/testing/TestClock";
import * as Scene from "foldkit/scene";
import { whoIsSignedIn } from "../src/flags.ts";
import { Message } from "../src/message.ts";
import { AppRoute } from "../src/route.ts";
import { update } from "../src/update.ts";
import { view } from "../src/view.ts";
import { ana, signedOut } from "./fixture.ts";

/** A server that answers each ask with the next of `answers`, and counts the asks. */
const server = (...answers: ReadonlyArray<() => Response | "never">) => {
  const asked = { times: 0 };
  const client = HttpClient.make((request) => {
    const answer = answers[Math.min(asked.times++, answers.length - 1)]!();
    return answer === "never" ? Effect.never : Effect.succeed(HttpClientResponse.fromWeb(request, answer));
  }).pipe(HttpClient.mapRequest(HttpClientRequest.prependUrl("http://localhost")));
  return { asked, ask: whoIsSignedIn.pipe(Effect.provideService(HttpClient.HttpClient, client)) };
};
const says = (status: number, body?: unknown) => () => new Response(body === undefined ? null : JSON.stringify(body), { status });

describe("opening the app", () => {
  it.effect("is signed in as the athlete the server names", () =>
    Effect.gen(function* () {
      expect(yield* server(says(200, { athleteId: ana })).ask).toEqual({ athleteId: ana, unreachable: false });
    }),
  );

  it.effect("is signed out only when the server says so, and asks once", () =>
    Effect.gen(function* () {
      const { ask, asked } = server(says(401));
      expect(yield* ask).toEqual({ athleteId: null, unreachable: false });
      expect(asked.times).toBe(1);
    }),
  );

  it.effect("asks again when the server fails, and opens with its answer", () =>
    Effect.gen(function* () {
      const { ask, asked } = server(says(503), says(200, { athleteId: ana }));
      const fiber = yield* Effect.forkChild(ask);
      yield* TestClock.adjust("5 seconds");
      expect(yield* Fiber.join(fiber)).toEqual({ athleteId: ana, unreachable: false });
      expect(asked.times).toBe(2);
    }),
  );

  it.effect("says it couldn't reach the server when it never answers, instead of signing the athlete out", () =>
    Effect.gen(function* () {
      const { ask, asked } = server(() => "never");
      const fiber = yield* Effect.forkChild(ask);
      yield* TestClock.adjust("1 minutes");
      expect(yield* Fiber.join(fiber)).toEqual({ athleteId: null, unreachable: true });
      expect(asked.times).toBe(3);
    }),
  );

  it.effect("doesn't take an answer it can't read for signed out", () =>
    Effect.gen(function* () {
      const { ask } = server(says(200, { athlete: "?" }));
      const fiber = yield* Effect.forkChild(ask);
      yield* TestClock.adjust("5 seconds");
      expect(yield* Fiber.join(fiber)).toEqual({ athleteId: null, unreachable: true });
    }),
  );

  const unreachable = { ...signedOut, unreachable: true, route: AppRoute.Plan() };

  it("offers to try again, not to connect with Intervals.icu", () =>
    Scene.scene(
      { update, view },
      Scene.given(unreachable),
      Scene.expect(Scene.text("No se pudo conectar con Cadencia")).toExist(),
      Scene.expect(Scene.role("button", { name: "Reintentar" })).toExist(),
      Scene.expect(Scene.role("link", { name: "Conectar con Intervals.icu" })).toBeAbsent(),
    ));

  it("tries again by loading the page it was opened on", () => {
    const again = update(unreachable, Message.ClickedRetryStart());
    expect(again.commands?.map((c) => [c.name, c.args])).toEqual([["LoadPage", { href: "/plan" }]]);
  });
});
