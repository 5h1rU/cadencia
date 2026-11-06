import { AthleteId } from "@cadencia/identity/Athlete.id";
import { Day } from "@cadencia/kernel/Calendar/Day";
import { Weekday } from "@cadencia/kernel/Calendar/Week";
import { Paragraph, Title } from "@cadencia/kernel/Text";
import { GoalKind } from "@cadencia/kernel/Training/Goal";
import { Phase } from "@cadencia/kernel/Training/Phase";
import { SessionKind } from "@cadencia/kernel/Training/SessionKind";
import { Kilometers, Minutes } from "@cadencia/kernel/Training/Units";
import * as Schema from "effect/Schema";

/** The plan the coach drafted from a consultation, in the coach's language. Planning turns it into a plan. */
export const PlanDraft = Schema.Struct({
  athleteId: AthleteId,
  title: Title,
  goal: GoalKind,
  objective: Paragraph,
  rationale: Paragraph,
  startDay: Day,
  endDay: Day,
  phases: Schema.Array(Phase),
  longRideWeekday: Weekday,
  event: Schema.NullOr(
    Schema.Struct({ name: Title, day: Day, distanceKm: Schema.NullOr(Kilometers), isRace: Schema.Boolean }),
  ),
  sessions: Schema.Array(
    Schema.Struct({ day: Day, kind: SessionKind, title: Title, targetMinutes: Minutes, purpose: Paragraph }),
  ),
});
export type PlanDraft = typeof PlanDraft.Type;
