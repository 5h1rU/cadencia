import { Authenticated } from "@cadencia/identity/Authenticated.middleware";
import { NotYours } from "@cadencia/identity/NotYours.rejection";
import { Day } from "@cadencia/kernel/Calendar/Day";
import { PlanId } from "@cadencia/kernel/Plan.id";
import * as Domain from "@alchemy.run/domain";
import * as Schema from "effect/Schema";
import { PlanNotActive } from "./PlanNotActive.rejection.ts";
import { ExternalId } from "./Session.id.ts";
import { ImplausibleToday } from "./ImplausibleToday.rejection.ts";

export class PlanRetired extends Domain.Event("PlanRetired", {
  /** Upcoming sessions to take off the Intervals calendar. */
  withdrawn: Schema.Array(ExternalId),
}) {}

/**
 * Retire the plan. Its sessions from `today`, the athlete's local day, leave
 * the Intervals calendar; earlier ones stay, as the athlete may have ridden them.
 */
export class RetirePlan extends Domain.Command("RetirePlan", {
  target: PlanId,
  middleware: [Authenticated],
  input: { today: Day },
  events: [PlanRetired],
  rejects: [PlanNotActive, ImplausibleToday, NotYours],
}) {}
