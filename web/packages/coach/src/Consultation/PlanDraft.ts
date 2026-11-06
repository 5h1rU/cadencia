import { AthleteId } from "@cadencia/kernel/Athlete.id";
import { Day } from "@cadencia/kernel/Day";
import { SessionKind } from "@cadencia/kernel/SessionKind";
import * as Schema from "effect/Schema";

/** The plan the coach drafted from a consultation, in the coach's language. Planning turns it into a plan. */
export const PlanDraft = Schema.Struct({
  athleteId: AthleteId,
  title: Schema.String,
  goal: Schema.Literals(["climbing", "ftp", "durability", "endurance", "vo2max", "event", "strength"]),
  objective: Schema.String,
  rationale: Schema.String,
  startDay: Day,
  endDay: Day,
  phases: Schema.Array(
    Schema.Struct({
      focus: Schema.Literals(["prepare", "base", "build", "peak", "taper", "consolidate", "recover"]),
      startWeek: Schema.Int,
      endWeek: Schema.Int,
      summary: Schema.String,
    }),
  ),
  longRideWeekday: Schema.Int,
  event: Schema.NullOr(
    Schema.Struct({ name: Schema.String, day: Day, distanceKm: Schema.NullOr(Schema.Number), isRace: Schema.Boolean }),
  ),
  sessions: Schema.Array(
    Schema.Struct({
      day: Day,
      kind: SessionKind,
      title: Schema.String,
      targetMinutes: Schema.Int,
      purpose: Schema.String,
    }),
  ),
});
export type PlanDraft = typeof PlanDraft.Type;
