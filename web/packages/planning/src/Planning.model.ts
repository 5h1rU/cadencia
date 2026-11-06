import * as Domain from "@alchemy.run/domain";
import * as Layer from "effect/Layer";
import { CalendarPublishing, CalendarPublishingLive } from "./Plan/CalendarPublishing.policy.ts";
import { CurrentPlan } from "./Plan/CurrentPlan.view.ts";
import { Plan } from "./Plan/Plan.aggregate.ts";

/** Planning: the intent of each training plan and the rules every change must respect. */
export class Planning extends Domain.Model("Planning", {
  aggregates: [Plan],
  views: [CurrentPlan],
  policies: [CalendarPublishing],
}) {}

/** The publishing policy's implementation. Requires the `Calendar` external system. */
export const PlanningHandlers = Layer.mergeAll(CalendarPublishingLive);
