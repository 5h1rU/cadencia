import * as Domain from "@alchemy.run/domain";
import { Planning } from "./Planning.model.ts";

/** What Cadencia iOS reaches, published over HTTP at `/v1`: the plan, and changes that need no AI. */
export class IosPlanningApi extends Domain.Api("IosPlanningApi", {
  model: Planning,
  commands: ["MoveSession", "RecordDayRequirement", "RetirePlan"],
  views: ["CurrentPlan"],
  streams: [],
}) {}
