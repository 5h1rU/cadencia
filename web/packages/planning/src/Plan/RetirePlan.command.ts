import { NotYours } from "@cadencia/kernel/NotYours.rejection";
import { Session } from "@cadencia/kernel/Session.middleware";
import * as Domain from "@alchemy.run/domain";
import * as Schema from "effect/Schema";
import { PlanId } from "./Plan.id.ts";
import { PlanNotActive } from "./PlanNotActive.rejection.ts";

export class PlanRetired extends Domain.Event("PlanRetired", {
  /** Upcoming sessions to take off the Intervals calendar. */
  withdrawn: Schema.Array(Schema.String),
}) {}

/** Retire the plan. Its upcoming sessions leave the Intervals calendar. */
export class RetirePlan extends Domain.Command(
  "RetirePlan",
  {
    target: PlanId,
    middleware: [Session],
    input: {},
    events: [PlanRetired],
    rejects: [PlanNotActive, NotYours],
  }
) {}
