import { athlete } from "@cadencia/identity/Actor";
import { AthleteId } from "@cadencia/identity/Athlete.id";
import * as Effect from "effect/Effect";
import * as Base64Url from "effect/encoding/Base64Url";
import * as Cookies from "effect/http/Cookies";
import * as Headers from "effect/http/Headers";
import * as HttpServerResponse from "effect/http/HttpServerResponse";
import * as Option from "effect/Option";
import * as Redacted from "effect/Redacted";
import * as Result from "effect/Result";
import * as Schema from "effect/Schema";
import { Connections } from "../Connections.ts";
import { InvalidHandoff, type SignedToken, SignInClient, SignInExpired, SignInRefused } from "@cadencia/web-api/AuthGroup";
import { signHandoff, signSession, verifyHandoff, withSessionCookie } from "../Session.ts";
import { INTERVALS } from "./IntervalsHttp.ts";

/** What Cadencia needs from Intervals: the same scopes Cadencia iOS asks for. */
export const SCOPES = ["ACTIVITY:WRITE", "WELLNESS:WRITE", "CALENDAR:WRITE", "SETTINGS:WRITE", "CHATS:WRITE"] as const;

/** Where a sign-in returns: the web app, or Cadencia iOS through its URL scheme. */
const IOS_CALLBACK = "cadencia://auth/callback";

const FLOW_COOKIE = "cadencia_oauth";

/** 32 random bytes in base64url: the OAuth `state` and the PKCE verifier are both made this way. */
const RandomToken = Schema.String.pipe(Schema.check(Schema.isPattern(/^[A-Za-z0-9_-]{43}$/)));
const OAuthState = RandomToken.pipe(Schema.brand("OAuthState"));
const PkceVerifier = RandomToken.pipe(Schema.brand("PkceVerifier"));

/** The sign-in in progress, kept in a short-lived cookie. */
const Flow = Schema.fromJsonString(Schema.Struct({ state: OAuthState, verifier: PkceVerifier, client: SignInClient }));

/** A permission Cadencia asks Intervals for. */
const IntervalsScope = Schema.Literals(SCOPES);

/** What Intervals answers when it exchanges the code; the token never appears in logs. */
const TokenResponse = Schema.Struct({
  access_token: Schema.RedactedFromValue(Schema.String),
  scope: Schema.String,
  athlete: Schema.Struct({ id: AthleteId }),
});

const scopesOf = (scope: string): ReadonlyArray<typeof IntervalsScope.Type> =>
  scope.split(",").flatMap((s) => Option.toArray(Schema.decodeUnknownOption(IntervalsScope)(s.trim())));

const randomToken = () => Base64Url.encode(crypto.getRandomValues(new Uint8Array(32)));

const challengeOf = (verifier: string) =>
  Effect.promise(async () =>
    Base64Url.encode(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier)))),
  );

export interface OAuthConfig {
  readonly clientId: string;
  /** Issued with the OAuth app in Intervals.icu settings. Only the server holds it. */
  readonly clientSecret: Redacted.Redacted<string>;
  /** The callback registered for this OAuth app in Intervals: `<origin>/auth/intervals/callback`. */
  readonly redirectUri: string;
}

/**
 * Send the athlete to Intervals to authorize Cadencia, with PKCE. The flow
 * (its state and verifier) waits in a short-lived cookie for the callback.
 */
export const startSignIn = Effect.fn(function* (config: OAuthConfig, client: SignInClient) {
  const state = OAuthState.make(randomToken());
  const verifier = PkceVerifier.make(randomToken());
  const authorize = new URL("/oauth/authorize", INTERVALS);
  authorize.searchParams.set("client_id", config.clientId);
  authorize.searchParams.set("redirect_uri", config.redirectUri);
  authorize.searchParams.set("scope", SCOPES.join(","));
  authorize.searchParams.set("state", state);
  authorize.searchParams.set("code_challenge", yield* challengeOf(verifier));
  authorize.searchParams.set("code_challenge_method", "S256");
  const flow = yield* Schema.encodeEffect(Flow)({ state, verifier, client }).pipe(Effect.orDie);
  return HttpServerResponse.redirect(authorize.toString(), { status: 302 }).pipe(
    HttpServerResponse.setCookieUnsafe(FLOW_COOKIE, Base64Url.encode(flow), {
      httpOnly: true,
      secure: true,
      sameSite: "lax",
      path: "/auth",
      maxAge: "10 minutes",
    }),
  );
});

/** The sign-in a request's flow cookie says is in progress, if it is readable. */
const flowOf = (headers: Headers.Headers) => {
  const cookie = Option.flatMap(Headers.get(headers, "cookie"), (c) => Option.fromNullishOr(Cookies.parseHeader(c)[FLOW_COOKIE]));
  const json = Option.flatMap(cookie, (c) => {
    const decoded = Base64Url.decodeString(c);
    return Result.isSuccess(decoded) ? Option.some(decoded.success) : Option.none();
  });
  return Option.isSome(json) ? Schema.decodeEffect(Flow)(json.value).pipe(Effect.option) : Effect.succeedNone;
};

/**
 * Where Intervals returns: exchange the code, keep the athlete's Intervals
 * token (encrypted), and sign them in, with a cookie for the web or a
 * one-minute handoff token for iOS to exchange.
 */
export const finishSignIn = Effect.fn(function* (
  config: OAuthConfig,
  query: { readonly code?: string | undefined; readonly state?: string | undefined },
  headers: Headers.Headers,
) {
  const flow = yield* flowOf(headers);
  const { code, state } = query;
  if (!code || !state || Option.isNone(flow) || flow.value.state !== state) return yield* new SignInExpired();
  const exchanged = yield* Effect.tryPromise(async () => {
    const response = await fetch(new URL("/api/oauth/token", INTERVALS), {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded", accept: "application/json" },
      body: new URLSearchParams({
        client_id: config.clientId,
        client_secret: Redacted.value(config.clientSecret),
        code,
        code_verifier: flow.value.verifier,
        redirect_uri: config.redirectUri,
      }),
    });
    if (!response.ok) throw new Error(`Intervals refused the code: ${response.status}`);
    return (await response.json()) as unknown;
  }).pipe(
    Effect.flatMap(Schema.decodeUnknownEffect(TokenResponse)),
    Effect.mapError(() => new SignInRefused()),
  );
  const athleteId = exchanged.athlete.id;
  yield* (yield* Connections).save({ athleteId, token: exchanged.access_token, scopes: scopesOf(exchanged.scope) });
  const clearFlow = HttpServerResponse.setCookieUnsafe(FLOW_COOKIE, "", { path: "/auth", maxAge: 0 });
  if (flow.value.client === "ios") {
    const handoff = yield* signHandoff(athlete(athleteId));
    return HttpServerResponse.redirect(`${IOS_CALLBACK}?handoff=${encodeURIComponent(handoff)}`, { status: 302 }).pipe(
      clearFlow,
    );
  }
  const session = yield* signSession(athlete(athleteId));
  return HttpServerResponse.redirect("/", { status: 302 }).pipe(clearFlow, withSessionCookie(session));
});

/**
 * Turn an iOS handoff token into a session token for `Authorization: Bearer`,
 * and hand the athlete's device their own Intervals token: Cadencia iOS
 * uploads rides and reads activities from Intervals itself.
 */
export const exchangeHandoff = Effect.fn(function* (handoff: SignedToken) {
  const actor = yield* verifyHandoff(handoff);
  if (Option.isNone(actor) || actor.value._tag !== "Athlete") return yield* new InvalidHandoff();
  const connection = yield* (yield* Connections).find(actor.value.athleteId);
  if (Option.isNone(connection)) return yield* new InvalidHandoff();
  return { token: yield* signSession(actor.value), intervalsAccessToken: connection.value.token };
});
