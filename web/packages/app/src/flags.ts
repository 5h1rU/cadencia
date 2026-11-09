import { AthleteId } from "@cadencia/identity/Athlete.id";
import * as Data from "effect/Data";
import * as Effect from "effect/Effect";
import * as HttpClient from "effect/http/HttpClient";
import * as HttpClientResponse from "effect/http/HttpClientResponse";
import * as Schedule from "effect/Schedule";
import * as Schema from "effect/Schema";
import { localDayOf } from "./subscription.ts";

/** The server didn't say who is signed in: it failed, answered something else, or took too long. */
class NoAnswer extends Data.TaggedError("NoAnswer")<{}> {}

/** How long one ask may take, and how often it is asked again before the app opens without an answer. */
export const ANSWER_DEADLINE = "8 seconds";
export const ASKS_AGAIN = 2;

/**
 * One ask: the athlete the cookie belongs to, or `null` when the server says
 * nobody is signed in (401). Anything else is no answer.
 */
const ask: Effect.Effect<AthleteId | null, NoAnswer, HttpClient.HttpClient> = Effect.gen(function* () {
  const response = yield* HttpClient.get("/api/session");
  if (response.status === 401) return null;
  if (response.status !== 200) return yield* new NoAnswer();
  const { athleteId } = yield* HttpClientResponse.schemaBodyJson(Schema.Struct({ athleteId: AthleteId }))(response);
  return athleteId;
}).pipe(
  Effect.timeoutOrElse({ duration: ANSWER_DEADLINE, orElse: () => Effect.fail(new NoAnswer()) }),
  Effect.catch(() => Effect.fail(new NoAnswer())),
);

/**
 * Who is signed in: the cookie is HttpOnly, so the app asks the server. Only
 * the server saying so is signed out; when it can't be reached the app opens
 * saying that, instead of sending a signed-in athlete to sign in again.
 */
export const whoIsSignedIn = ask.pipe(
  Effect.retry({ times: ASKS_AGAIN, schedule: Schedule.exponential("400 millis") }),
  Effect.map((athleteId) => ({ athleteId, unreachable: false })),
  Effect.catch(() => Effect.succeed({ athleteId: null, unreachable: true })),
);

/** What the app starts with. `pageLoad` names this load's commands, so each is unique even across reloads. */
export const flags = Effect.gen(function* () {
  const { athleteId, unreachable } = yield* whoIsSignedIn;
  return {
    athleteId,
    unreachable,
    // Today in the athlete's own time zone; the app moves it on at local midnight.
    today: localDayOf(new Date()),
    pageLoad: crypto.randomUUID(),
  };
});
