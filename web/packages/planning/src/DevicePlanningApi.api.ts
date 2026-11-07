import * as Domain from "@alchemy.run/domain";
import { Planning } from "./Planning.model.ts";

/** What the athlete's device (Cadencia iOS) reaches, published over HTTP at `/v1`: the plan, and changes that need no AI. */
export class DevicePlanningApi extends Domain.Api("DevicePlanningApi", {
  model: Planning,
  commands: ["MoveSession", "RecordDayRequirement", "RetirePlan"],
  views: ["CurrentPlan"],
  streams: [],
}) {}
