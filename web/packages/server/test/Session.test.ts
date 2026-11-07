import { athlete } from "@cadencia/identity/Actor";
import { CurrentActor } from "@cadencia/identity/CurrentActor.context";
import { Session, SESSION_COOKIE, Unauthorized } from "@cadencia/identity/Session.middleware";
import { describe, expect, it } from "@effect/vitest";
import * as Effect from "effect/Effect";
import * as Headers from "effect/http/Headers";
import * as Layer from "effect/Layer";
import * as Option from "effect/Option";
import { TestClock } from "effect/testing";
import { actorOf, SESSION_DAYS, SessionLive, signHandoff, signSession, verifyHandoff } from "../src/Session.ts";
import { SessionKeyTest } from "./session.ts";

const ana = athlete("i100");

const bearer = (token: string) => Headers.fromInput({ authorization: `Bearer ${token}` });

/** Replace the character at `index` with a different base64url character. */
const tamper = (text: string, index: number) =>
  `${text.slice(0, index)}${text[index] === "A" ? "B" : "A"}${text.slice(index + 1)}`;

describe("session tokens", () => {
  it.effect("a session token names its athlete until it expires", () =>
    Effect.gen(function* () {
      const token = yield* signSession(ana);
      expect(yield* actorOf(bearer(token))).toEqual(Option.some(ana));
      yield* TestClock.adjust(`${SESSION_DAYS} days`);
      yield* TestClock.adjust("1 second");
      expect(yield* actorOf(bearer(token))).toEqual(Option.none());
    }).pipe(Effect.provide(SessionKeyTest)),
  );

  it.effect("a token whose MAC or claims were changed is refused", () =>
    Effect.gen(function* () {
      const token = yield* signSession(ana);
      const [claims, mac] = token.split(".") as [string, string];
      expect(yield* actorOf(bearer(`${claims}.${tamper(mac, 0)}`))).toEqual(Option.none());
      expect(yield* actorOf(bearer(`${tamper(claims, 0)}.${mac}`))).toEqual(Option.none());
      expect(yield* actorOf(bearer(`${tamper(claims, claims.length - 3)}.${mac}`))).toEqual(Option.none());
    }).pipe(Effect.provide(SessionKeyTest)),
  );

  it.effect("a handoff is not a session, and a session is not a handoff", () =>
    Effect.gen(function* () {
      const handoff = yield* signHandoff(ana);
      const session = yield* signSession(ana);
      expect(yield* actorOf(bearer(handoff))).toEqual(Option.none());
      expect(yield* verifyHandoff(session)).toEqual(Option.none());
      expect(yield* verifyHandoff(handoff)).toEqual(Option.some(ana));
    }).pipe(Effect.provide(SessionKeyTest)),
  );

  it.effect("a handoff lasts one minute", () =>
    Effect.gen(function* () {
      const handoff = yield* signHandoff(ana);
      yield* TestClock.adjust("59 seconds");
      expect(yield* verifyHandoff(handoff)).toEqual(Option.some(ana));
      yield* TestClock.adjust("2 seconds");
      expect(yield* verifyHandoff(handoff)).toEqual(Option.none());
    }).pipe(Effect.provide(SessionKeyTest)),
  );

  it.effect("a request without a session cookie or Bearer token has no actor", () =>
    Effect.gen(function* () {
      const token = yield* signSession(ana);
      expect(yield* actorOf(Headers.empty)).toEqual(Option.none());
      expect(yield* actorOf(Headers.fromInput({ authorization: `Basic ${token}` }))).toEqual(Option.none());
      expect(yield* actorOf(Headers.fromInput({ authorization: token }))).toEqual(Option.none());
      expect(yield* actorOf(Headers.fromInput({ cookie: `other=${token}` }))).toEqual(Option.none());
    }).pipe(Effect.provide(SessionKeyTest)),
  );

  it.effect("the session cookie names its athlete", () =>
    Effect.gen(function* () {
      const token = yield* signSession(ana);
      const headers = Headers.fromInput({ cookie: `theme=dark; ${SESSION_COOKIE}=${token}` });
      expect(yield* actorOf(headers)).toEqual(Option.some(ana));
    }).pipe(Effect.provide(SessionKeyTest)),
  );
});

describe("SessionLive", () => {
  const World = SessionLive.pipe(Layer.provideMerge(SessionKeyTest));
  const currentActor = Effect.gen(function* () {
    return yield* CurrentActor;
  });

  /** Run `effect` through the middleware as a request with these headers. */
  const throughSession = <A>(effect: Effect.Effect<A, never, CurrentActor>, headers: Headers.Headers) =>
    Effect.gen(function* () {
      const middleware = yield* Session;
      return yield* middleware(effect as never, { headers } as never);
    }).pipe(Effect.scoped, Effect.provide(World));

  it.effect("provides the actor of a valid session", () =>
    Effect.gen(function* () {
      const token = yield* signSession(ana).pipe(Effect.provide(SessionKeyTest));
      const actor = yield* throughSession(currentActor, bearer(token));
      expect(actor).toEqual(ana);
    }),
  );

  it.effect("fails with Unauthorized when the request carries no session", () =>
    Effect.gen(function* () {
      const error = yield* throughSession(currentActor, Headers.empty).pipe(Effect.flip);
      expect(error).toBeInstanceOf(Unauthorized);
    }),
  );

  it.effect("fails with Unauthorized for an expired session", () =>
    Effect.gen(function* () {
      const token = yield* signSession(ana).pipe(Effect.provide(SessionKeyTest));
      yield* TestClock.adjust(`${SESSION_DAYS + 1} days`);
      const error = yield* throughSession(currentActor, bearer(token)).pipe(Effect.flip);
      expect(error).toBeInstanceOf(Unauthorized);
    }),
  );
});
