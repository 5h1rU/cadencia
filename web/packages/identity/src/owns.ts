import * as Effect from "effect/Effect";
import type { SystemName } from "./Actor.ts";
import type { AthleteId } from "./Athlete.id.ts";
import { CurrentActor } from "./CurrentActor.context.ts";
import { NotYours } from "./NotYours.rejection.ts";

/**
 * Who may act on or read an athlete's data: that athlete, or the system. Data
 * that does not exist yet (owner null) reads as empty, so a client can watch
 * for it to appear.
 */
export const mustOwn = Effect.fn(function* (owner: AthleteId | null) {
  const actor = yield* CurrentActor;
  if (actor._tag === "System" || owner === null) return;
  if (actor.athleteId !== owner) return yield* new NotYours();
});

/** Commands only one part of Cadencia sends on its own, such as the Intervals sync. */
export const mustBeSystem = Effect.fn(function* (name: SystemName) {
  const actor = yield* CurrentActor;
  if (actor._tag !== "System" || actor.name !== name) return yield* new NotYours();
});
