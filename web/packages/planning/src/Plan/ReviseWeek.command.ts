import { Authenticated } from "@cadencia/identity/Authenticated.middleware";
import { NotYours } from "@cadencia/identity/NotYours.rejection";
import { Day } from "@cadencia/kernel/Calendar/Day";
import { PlanId } from "@cadencia/kernel/Plan.id";
import { DayLimit } from "@cadencia/kernel/Training/DayLimit";
import * as Domain from "@alchemy.run/domain";
import * as Schema from "effect/Schema";
import { ImplausibleToday } from "./ImplausibleToday.rejection.ts";
import { PlannedSession } from "./PlannedSession.ts";
import { PlanNotActive } from "./PlanNotActive.rejection.ts";

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
  middleware: [Authenticated],
  input: { limits: Schema.Array(DayLimit), today: Day },
  events: [WeekRevised],
  rejects: [PlanNotActive, ImplausibleToday, NotYours],
}) {}
