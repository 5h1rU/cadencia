import { AthleteId } from "@cadencia/identity/Athlete.id";
import * as HttpApiEndpoint from "effect/http-api/HttpApiEndpoint";
import * as HttpApiGroup from "effect/http-api/HttpApiGroup";
import * as HttpApiSchema from "effect/http-api/HttpApiSchema";
import * as OpenApi from "effect/http-api/OpenApi";
import * as Schema from "effect/Schema";
import { Authentication } from "./Authentication.middleware.ts";

/** Who is signed in. */
export const SignedIn = Schema.Struct({
  athleteId: AthleteId.annotate({ description: "The athlete's Intervals.icu id.", examples: [AthleteId.make("i393051")] }),
}).annotate({ title: "SignedIn", description: "The athlete the session belongs to." });

/** `GET` the session the request carries; `DELETE` signs out. */
export const SessionGroup = HttpApiGroup.make("session")
  .add(
    HttpApiEndpoint.get("current", "/session", { success: SignedIn })
      .middleware(Authentication)
      .annotate(OpenApi.Description, "Who is signed in. The cookie is HttpOnly, so the web asks here."),
  )
  .add(
    HttpApiEndpoint.delete("signOut", "/session", { success: HttpApiSchema.NoContent }).annotate(
      OpenApi.Description,
      "Sign out: clears the session cookie.",
    ),
  )
  .annotate(OpenApi.Description, "The athlete's session.");
