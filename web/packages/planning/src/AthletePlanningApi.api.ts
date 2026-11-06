import * as Domain from "@alchemy.run/domain";
import { Planning } from "./Planning.model.ts";

/** What the athlete reaches from the web and iOS: their plan, and changes that need no AI. */
export class AthletePlanningApi extends Domain.Api("AthletePlanningApi", {
  model: Planning,
  commands: ["MoveSession", "RecordDayRequirement", "RetirePlan"],
  views: ["CurrentPlan"],
  streams: [],
}) {}
