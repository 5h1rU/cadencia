import * as Schema from "effect/Schema";
import { AthleteId } from "./Athlete.id.ts";

/** The parts of Cadencia that act on their own: policies and scheduled jobs. */
export const SystemName = Schema.Literals(["coach", "CalendarPublishing", "IntervalsSync"]);
export type SystemName = typeof SystemName.Type;

/**
 * Who is acting. `Session` provides it for every request; policies act as a
 * named system actor.
 */
export const Actor = Schema.Union([
  Schema.TaggedStruct("Athlete", { athleteId: AthleteId }),
  Schema.TaggedStruct("System", { name: SystemName }),
]);
export type Actor = typeof Actor.Type;

export const athlete = (athleteId: string): Actor => ({
  _tag: "Athlete",
  athleteId: AthleteId.make(athleteId),
});
export const system = (name: SystemName): Actor => ({ _tag: "System", name });
