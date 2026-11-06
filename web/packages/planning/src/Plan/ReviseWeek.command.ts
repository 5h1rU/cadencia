import { Day } from "@cadencia/kernel/Day";
import { NotYours } from "@cadencia/kernel/NotYours.rejection";
import { Session } from "@cadencia/kernel/Session.middleware";
import * as Domain from "@alchemy.run/domain";
import * as Schema from "effect/Schema";
import { PlanId } from "./Plan.id.ts";
import { PlanNotActive } from "./PlanNotActive.rejection.ts";
import { PlannedSession } from "./PlanShape.ts";

/** A limit the athlete asked for on one day. A revision can only shorten or remove riding. */
export const DayLimit = Schema.Struct({
  day: Day,
  maxMinutes: Schema.NullOr(Schema.Int),
  unavailable: Schema.Boolean,
});
export type DayLimit = typeof DayLimit.Type;

export class WeekRevised extends Domain.Event("WeekRevised", {
  sessions: Schema.Array(PlannedSession),
}) {}

/** Apply the limits of an accepted intent to the plan. It never adds riding or intensity. */
export class ReviseWeek extends Domain.Command(
  "ReviseWeek",
  {
    target: PlanId,
    middleware: [Session],
    input: { limits: Schema.Array(DayLimit) },
    events: [WeekRevised],
    rejects: [PlanNotActive, NotYours],
  }
) {}
