import type { Actor } from "@cadencia/identity/Actor";
import { sessionClient } from "@cadencia/identity/Authenticated.middleware";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as Redacted from "effect/Redacted";
import { SessionKey, signSession } from "../src/Session.ts";

/** A fixed key in place of the deployed stage's random one. */
export const SessionKeyTest = Layer.succeed(
  SessionKey,
  Effect.succeed(Redacted.make("a-test-session-key-a-test-session-key")),
);

/** Client middleware that sends a session signed for `actor`. */
export const signedInAs = (actor: Actor) => Layer.unwrap(Effect.map(signSession(actor), sessionClient));
