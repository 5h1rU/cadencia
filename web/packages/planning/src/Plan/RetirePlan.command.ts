import { NotYours } from "@cadencia/identity/NotYours.rejection";
import { Session } from "@cadencia/identity/Session.middleware";
import { PlanId } from "@cadencia/kernel/Plan.id";
import * as Domain from "@alchemy.run/domain";
import * as Schema from "effect/Schema";
import { PlanNotActive } from "./PlanNotActive.rejection.ts";
import { ExternalId } from "./Session.id.ts";

export class PlanRetired extends Domain.Event("PlanRetired", {
  /** Upcoming sessions to take off the Intervals calendar. */
  withdrawn: Schema.Array(ExternalId),
}) {}

/** Retire the plan. Its upcoming sessions leave the Intervals calendar. */
export class RetirePlan extends Domain.Command("RetirePlan", {
  target: PlanId,
  middleware: [Session],
  input: {},
  events: [PlanRetired],
  rejects: [PlanNotActive, NotYours],
}) {}
