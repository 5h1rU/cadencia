import { type Actor, Actor as ActorSchema } from "@cadencia/identity/Actor";
import { CurrentActor } from "@cadencia/identity/CurrentActor.context";
import { SignedToken } from "@cadencia/web-api/AuthGroup";
import { Session, SESSION_COOKIE, Unauthorized } from "@cadencia/identity/Session.middleware";
import * as Alchemy from "alchemy";
import * as Clock from "effect/Clock";
import * as Context from "effect/Context";
import * as Effect from "effect/Effect";
import * as Base64Url from "effect/encoding/Base64Url";
import * as Cookies from "effect/http/Cookies";
import * as Headers from "effect/http/Headers";
import { HttpServerRequest } from "effect/http/HttpServerRequest";
import * as HttpServerResponse from "effect/http/HttpServerResponse";
import * as Layer from "effect/Layer";
import * as Option from "effect/Option";
import * as Redacted from "effect/Redacted";
import * as Result from "effect/Result";
import * as Schema from "effect/Schema";

/** How long a session lasts. */
export const SESSION_DAYS = 30;

/** The key that signs sessions: random, made once per stage and kept in its state. */
export class SessionKey extends Context.Service<SessionKey, Effect.Effect<Redacted.Redacted<string>>>()(
  "Cadencia/SessionKey",
) {}

export const SessionKeyLive = Layer.effect(
  SessionKey,
  Effect.gen(function* () {
    const key = yield* Alchemy.Random("SessionKey");
    return yield* key.text;
  }),
);

const hmacKey = Effect.fn(function* () {
  const secret = Redacted.value(yield* yield* SessionKey);
  return yield* Effect.promise(() =>
    crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, [
      "sign",
      "verify",
    ]),
  );
});

/** Milliseconds since the Unix epoch. */
const EpochMillis = Schema.Int.pipe(Schema.check(Schema.isGreaterThanOrEqualTo(0)), Schema.brand("EpochMillis"));

/** What a token is good for: a session, or a one-minute handoff from the browser to iOS. */
const TokenPurpose = Schema.Literals(["session", "handoff"]);
type TokenPurpose = typeof TokenPurpose.Type;

/** What a signed token says: who, for what, and until when. */
const Claims = Schema.fromJsonString(Schema.Struct({ actor: ActorSchema, purpose: TokenPurpose, expires: EpochMillis }));

const sign = Effect.fn(function* (actor: Actor, purpose: TokenPurpose, lifetimeMs: number) {
  const expires = EpochMillis.make((yield* Clock.currentTimeMillis) + lifetimeMs);
  const json = yield* Schema.encodeEffect(Claims)({ actor, purpose, expires }).pipe(Effect.orDie);
  const claims = Base64Url.encode(json);
  const key = yield* hmacKey();
  const signature = yield* Effect.promise(() => crypto.subtle.sign("HMAC", key, new TextEncoder().encode(claims)));
  return SignedToken.make(`${claims}.${Base64Url.encode(new Uint8Array(signature))}`);
});

const verify = Effect.fn(function* (token: string, purpose: TokenPurpose) {
  const [claims, mac, ...rest] = token.split(".");
  if (!claims || !mac || rest.length > 0) return Option.none<Actor>();
  const signature = Base64Url.decode(mac);
  if (Result.isFailure(signature)) return Option.none<Actor>();
  const key = yield* hmacKey();
  const valid = yield* Effect.promise(() =>
    crypto.subtle.verify("HMAC", key, new Uint8Array(signature.success), new TextEncoder().encode(claims)),
  );
  const json = Base64Url.decodeString(claims);
  if (!valid || Result.isFailure(json)) return Option.none<Actor>();
  const decoded = yield* Schema.decodeEffect(Claims)(json.success).pipe(Effect.option);
  const now = yield* Clock.currentTimeMillis;
  return Option.flatMap(decoded, (c) =>
    c.expires > now && c.purpose === purpose ? Option.some(c.actor) : Option.none(),
  );
});

/** A session token: what browsers carry in a cookie and iOS sends as `Authorization: Bearer`. */
export const signSession = (actor: Actor) => sign(actor, "session", SESSION_DAYS * 86_400_000);

/**
 * A one-minute token that hands a sign-in from the browser back to iOS. iOS
 * exchanges it at `/auth/exchange` for a session; it is useless for anything else.
 */
export const signHandoff = (actor: Actor) => sign(actor, "handoff", 60_000);
export const verifyHandoff = (token: string) => verify(token, "handoff");

/** The actor a session token names, if it is a session Cadencia signed that hasn't expired. */
export const verifySession = (token: string) => verify(token, "session");

const tokenOf = (headers: Headers.Headers): Option.Option<string> =>
  Option.orElse(
    Option.flatMap(Headers.get(headers, "cookie"), (cookie) =>
      Option.fromNullishOr(Cookies.parseHeader(cookie)[SESSION_COOKIE]),
    ),
    () =>
      Option.flatMap(Headers.get(headers, "authorization"), (value) =>
        value.startsWith("Bearer ") ? Option.some(value.slice("Bearer ".length)) : Option.none(),
      ),
  );

/** Who a request is from, if it carries a valid session. */
export const actorOf = Effect.fn(function* (headers: Headers.Headers) {
  const token = tokenOf(headers);
  return Option.isNone(token) ? Option.none<Actor>() : yield* verify(token.value, "session");
});

/** The {@link Session} middleware: provides the request's actor, or fails with Unauthorized. */
export const SessionLive = Layer.effect(
  Session,
  Effect.gen(function* () {
    const key = yield* SessionKey;
    return (effect, { headers }) =>
      actorOf(headers).pipe(
        Effect.provideService(SessionKey, key),
        Effect.flatMap(
          Option.match({
            onNone: () => Effect.fail(new Unauthorized()),
            onSome: (actor) => Effect.provideService(effect, CurrentActor, actor),
          }),
        ),
      );
  }),
);

/** The session middleware for code in the Worker that already knows who it acts for. */
export const actingAs = (actor: Actor) =>
  Layer.succeed(Session, (effect) => Effect.provideService(effect, CurrentActor, actor));

const cookieOptions = { httpOnly: true, secure: true, sameSite: "lax", path: "/" } as const;

/** Set the session cookie for an athlete. */
export const withSessionCookie = (token: string) =>
  HttpServerResponse.setCookieUnsafe(SESSION_COOKIE, token, { ...cookieOptions, maxAge: `${SESSION_DAYS} days` });

/** Clear the session cookie: sign out. */
export const withoutSessionCookie = HttpServerResponse.setCookieUnsafe(SESSION_COOKIE, "", { ...cookieOptions, maxAge: 0 });
