import { Day } from "@cadencia/kernel/Day";
import { NotYours } from "@cadencia/kernel/NotYours.rejection";
import { Session } from "@cadencia/kernel/Session.middleware";
import * as Domain from "@alchemy.run/domain";
import * as Schema from "effect/Schema";
import { DayOutsidePlan } from "./DayOutsidePlan.rejection.ts";
import { PlanId } from "./Plan.id.ts";
import { PlanNotActive } from "./PlanNotActive.rejection.ts";
import { DayRequirement } from "./PlanShape.ts";

export class DayRequirementRecorded extends Domain.Event("DayRequirementRecorded", {
  requirement: DayRequirement,
}) {}

/** Record what the athlete needs from one day ("Thursday, 45 minutes at most"). */
export class RecordDayRequirement extends Domain.Command(
  "RecordDayRequirement",
  {
    target: PlanId,
    middleware: [Session],
    input: { day: Day, instructions: Schema.String, maxMinutes: Schema.NullOr(Schema.Int) },
    events: [DayRequirementRecorded],
    rejects: [PlanNotActive, DayOutsidePlan, NotYours],
  }
) {}
