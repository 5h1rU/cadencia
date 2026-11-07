import { NotYours } from "@cadencia/identity/NotYours.rejection";
import { Session } from "@cadencia/identity/Session.middleware";
import { Day } from "@cadencia/kernel/Calendar/Day";
import { PlanId } from "@cadencia/kernel/Plan.id";
import { DayLimit } from "@cadencia/kernel/Training/DayLimit";
import * as Domain from "@alchemy.run/domain";
import * as Schema from "effect/Schema";
import { PlanNotActive } from "./PlanNotActive.rejection.ts";
import { PlannedSession } from "./PlanShape.ts";
import { ImplausibleToday } from "./ImplausibleToday.rejection.ts";

export class WeekRevised extends Domain.Event("WeekRevised", {
  sessions: Schema.Array(PlannedSession),
}) {}

/**
 * Apply the limits of an accepted intent to the plan. It never adds riding or
 * intensity, and it leaves days before `today` (the athlete's local day) alone:
 * those sessions may already be ridden.
 */
export class ReviseWeek extends Domain.Command("ReviseWeek", {
  target: PlanId,
  middleware: [Session],
  input: { limits: Schema.Array(DayLimit), today: Day },
  events: [WeekRevised],
  rejects: [PlanNotActive, ImplausibleToday, NotYours],
}) {}
