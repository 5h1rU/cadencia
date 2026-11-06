import { athlete } from "@cadencia/identity/Actor";
import { AthleteId } from "@cadencia/identity/Athlete.id";
import * as Effect from "effect/Effect";
import * as Base64Url from "effect/encoding/Base64Url";
import * as Cookies from "effect/http/Cookies";
import * as Headers from "effect/http/Headers";
import { HttpServerRequest } from "effect/http/HttpServerRequest";
import * as HttpServerResponse from "effect/http/HttpServerResponse";
import * as Option from "effect/Option";
import * as Redacted from "effect/Redacted";
import * as Result from "effect/Result";
import * as Schema from "effect/Schema";
import { Connections } from "../Connections.ts";
import { SignedToken, signHandoff, signSession, verifyHandoff, withSessionCookie } from "../Session.ts";
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

/** Where a sign-in returns to. */
const SignInClient = Schema.Literals(["web", "ios"]);

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
 * `GET /auth/intervals/start` sends the athlete to Intervals to authorize
 * Cadencia, with PKCE. `?client=ios` returns to Cadencia iOS afterwards.
 */
export const startRoute = (config: OAuthConfig) =>
  Effect.gen(function* () {
    const request = yield* HttpServerRequest;
    const url = new URL(request.url, "http://localhost");
    const client = url.searchParams.get("client") === "ios" ? "ios" : "web";
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

/**
 * `GET /auth/intervals/callback` exchanges the code, keeps the athlete's
 * Intervals token (encrypted), and signs them in: a cookie for the web, or a
 * one-minute handoff token for iOS to exchange.
 */
export const callbackRoute = (config: OAuthConfig) =>
  Effect.gen(function* () {
    const request = yield* HttpServerRequest;
    const connections = yield* Connections;
    const url = new URL(request.url, "http://localhost");
    const code = url.searchParams.get("code");
    const state = url.searchParams.get("state");
    const cookie = Option.flatMap(Headers.get(request.headers, "cookie"), (c) =>
      Option.fromNullishOr(Cookies.parseHeader(c)[FLOW_COOKIE]),
    );
    const flowJson = Option.flatMap(cookie, (c) => {
      const decoded = Base64Url.decodeString(c);
      return Result.isSuccess(decoded) ? Option.some(decoded.success) : Option.none();
    });
    const flow = Option.isSome(flowJson)
      ? yield* Schema.decodeEffect(Flow)(flowJson.value).pipe(Effect.option)
      : Option.none();
    if (!code || !state || Option.isNone(flow) || flow.value.state !== state) {
      return HttpServerResponse.text("The sign-in expired or was tampered with. Start again.", { status: 400 });
    }
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
    }).pipe(Effect.flatMap(Schema.decodeUnknownEffect(TokenResponse)), Effect.option);
    if (Option.isNone(exchanged)) {
      return HttpServerResponse.text("Intervals.icu did not accept the sign-in. Try again.", { status: 502 });
    }
    const athleteId = exchanged.value.athlete.id;
    yield* connections.save({ athleteId, token: exchanged.value.access_token, scopes: scopesOf(exchanged.value.scope) });
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

/** `POST /auth/exchange` turns an iOS handoff token into a session token for `Authorization: Bearer`. */
export const exchangeRoute = Effect.gen(function* () {
  const request = yield* HttpServerRequest;
  if (request.method !== "POST") return HttpServerResponse.empty({ status: 405 });
  const body = yield* request.json.pipe(
    Effect.flatMap(Schema.decodeUnknownEffect(Schema.Struct({ handoff: SignedToken }))),
    Effect.option,
  );
  if (Option.isNone(body)) return HttpServerResponse.text("Expected { handoff }", { status: 400 });
  const actor = yield* verifyHandoff(body.value.handoff);
  if (Option.isNone(actor)) return HttpServerResponse.empty({ status: 401 });
  return yield* HttpServerResponse.json({ token: yield* signSession(actor.value) });
});
