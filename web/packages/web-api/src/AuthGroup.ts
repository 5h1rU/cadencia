import * as HttpApiEndpoint from "effect/http-api/HttpApiEndpoint";
import * as HttpApiGroup from "effect/http-api/HttpApiGroup";
import * as HttpApiSchema from "effect/http-api/HttpApiSchema";
import * as OpenApi from "effect/http-api/OpenApi";
import * as Schema from "effect/Schema";

/** A token Cadencia signed: base64url claims, a dot, and their base64url HMAC. */
export const SignedToken = Schema.String.pipe(
  Schema.check(Schema.isPattern(/^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]{43}$/)),
  Schema.brand("SignedToken"),
).annotate({ description: "A token Cadencia signed." });
export type SignedToken = typeof SignedToken.Type;

/** Where a sign-in returns to: the web app, or Cadencia iOS through its URL scheme. */
export const SignInClient = Schema.Literals(["web", "ios"]);
export type SignInClient = typeof SignInClient.Type;

/** The sign-in expired, was tampered with, or never started here. */
export class SignInExpired extends Schema.TaggedError<SignInExpired>()(
  "SignInExpired",
  {},
  { httpApiStatus: 400, description: "The sign-in expired or was tampered with. Start again." },
) {}

/** Intervals.icu didn't accept the sign-in. */
export class SignInRefused extends Schema.TaggedError<SignInRefused>()(
  "SignInRefused",
  {},
  { httpApiStatus: 502, description: "Intervals.icu did not accept the sign-in. Try again." },
) {}

/** The handoff isn't one Cadencia signed for this, or it is older than a minute. */
export class InvalidHandoff extends Schema.TaggedError<InvalidHandoff>()(
  "InvalidHandoff",
  {},
  { httpApiStatus: 401, description: "The handoff expired or is not a handoff." },
) {}

/** A redirect: the response is `302` with a `Location`. */
const Redirect = HttpApiSchema.Empty(302).annotate({ description: "Redirects the browser." });

/**
 * Signing in with Intervals.icu (OAuth with PKCE). The web gets a session
 * cookie; Cadencia iOS gets a one-minute handoff it exchanges for a session
 * token.
 */
export const AuthGroup = HttpApiGroup.make("auth")
  .add(
    HttpApiEndpoint.get("start", "/intervals/start", {
      query: { client: Schema.optional(SignInClient) },
      success: Redirect,
    }).annotate(
      OpenApi.Description,
      "Send the athlete to Intervals.icu to authorize Cadencia. `client=ios` returns to Cadencia iOS afterwards.",
    ),
  )
  .add(
    HttpApiEndpoint.get("callback", "/intervals/callback", {
      query: { code: Schema.optional(Schema.String), state: Schema.optional(Schema.String) },
      success: Redirect,
      error: [SignInExpired, SignInRefused],
    }).annotate(
      OpenApi.Description,
      "Where Intervals.icu returns: keeps the athlete's token and signs them in, with a cookie for the web or a handoff for iOS.",
    ),
  )
  .add(
    HttpApiEndpoint.post("exchange", "/exchange", {
      payload: Schema.Struct({ handoff: SignedToken }),
      success: Schema.Struct({
        token: SignedToken.annotate({ description: "A Cadencia session token for `Authorization: Bearer` on `/v1`." }),
        intervalsAccessToken: Schema.RedactedFromValue(Schema.String).annotate({
          description: "The athlete's own Intervals.icu OAuth token, for the calls Cadencia iOS makes to Intervals itself.",
        }),
      }).annotate({ title: "SignedInDevice" }),
      error: InvalidHandoff,
    }).annotate(
      OpenApi.Description,
      "Turn an iOS handoff into a session token, and give the athlete's device their Intervals.icu token.",
    ),
  )
  .annotate(OpenApi.Description, "Signing in with Intervals.icu.");
