import * as Effect from "effect/Effect";
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

/** The athlete an id belongs to: every athlete-scoped id starts with `<athleteId>:`. */
export const ownerOf = (id: string): string => id.slice(0, id.indexOf(":"));

/** A command's input without its tag, to copy into an event. */
export const inputOf = <A extends { readonly _tag: string }>(command: A): Omit<A, "_tag"> => {
  const { _tag: _, ...input } = command;
  return input;
};
