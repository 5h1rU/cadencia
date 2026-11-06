import * as Schema from "effect/Schema";
import { AthleteId } from "./Athlete.id.ts";

/**
 * Who is acting. `Session` provides it for every request; policies act as a
 * named system actor.
 */
export const Actor = Schema.Union([
  Schema.TaggedStruct("Athlete", { athleteId: AthleteId }),
  Schema.TaggedStruct("System", { name: Schema.String }),
]);
export type Actor = typeof Actor.Type;

export const athlete = (athleteId: string): Actor => ({
  _tag: "Athlete",
  athleteId: AthleteId.make(athleteId),
});
export const system = (name: string): Actor => ({ _tag: "System", name });
