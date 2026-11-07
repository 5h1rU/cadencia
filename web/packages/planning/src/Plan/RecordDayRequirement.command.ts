import { NotYours } from "@cadencia/identity/NotYours.rejection";
import { Session } from "@cadencia/identity/Session.middleware";
import { Day } from "@cadencia/kernel/Calendar/Day";
import { PlanId } from "@cadencia/kernel/Plan.id";
import { Paragraph } from "@cadencia/kernel/Text";
import { Minutes } from "@cadencia/kernel/Training/Units";
import * as Domain from "@alchemy.run/domain";
import * as Schema from "effect/Schema";
import { DayOutsidePlan } from "./DayOutsidePlan.rejection.ts";
import { DayRequirement } from "./DayRequirement.ts";
import { PlanNotActive } from "./PlanNotActive.rejection.ts";
import { WeekRevised } from "./ReviseWeek.command.ts";

export class DayRequirementRecorded extends Domain.Event("DayRequirementRecorded", {
  requirement: DayRequirement,
}) {}

/**
 * Record what the athlete needs from one day ("Thursday, 45 minutes at most").
 * A limit applies to the planned session at once, as an accepted intent does.
 */
export class RecordDayRequirement extends Domain.Command("RecordDayRequirement", {
  target: PlanId,
  middleware: [Session],
  input: { day: Day, instructions: Paragraph, maxMinutes: Schema.NullOr(Minutes) },
  events: [DayRequirementRecorded, WeekRevised],
  rejects: [PlanNotActive, DayOutsidePlan, NotYours],
}) {}
