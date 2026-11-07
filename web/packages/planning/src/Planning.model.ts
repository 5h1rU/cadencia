import * as Domain from "@alchemy.run/domain";
import * as Layer from "effect/Layer";
import { ActivePlan } from "./ActivePlan/ActivePlan.aggregate.ts";
import { PlanActivation, PlanActivationLive } from "./ActivePlan/PlanActivation.policy.ts";
import { PlanReplacement, PlanReplacementLive } from "./ActivePlan/PlanReplacement.policy.ts";
import { CalendarPublishing, CalendarPublishingLive } from "./Plan/CalendarPublishing.policy.ts";
import { CurrentPlan } from "./Plan/CurrentPlan.view.ts";
import { Plan } from "./Plan/Plan.aggregate.ts";

/** Planning: the intent of each training plan and the rules every change must respect. */
export class Planning extends Domain.Model("Planning", {
  aggregates: [Plan, ActivePlan],
  views: [CurrentPlan],
  policies: [CalendarPublishing, PlanActivation, PlanReplacement],
}) {}

/** The policies' implementations. `CalendarPublishing` requires the `Calendar` external system. */
export const PlanningHandlers = Layer.mergeAll(CalendarPublishingLive, PlanActivationLive, PlanReplacementLive);
