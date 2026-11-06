import * as Domain from "@alchemy.run/domain";
import { Planning } from "./Planning.model.ts";

/**
 * What the Coach model reaches, in process, as a system actor: changes that
 * come from an AI interpretation and must pass the plan's rules.
 */
export class CoachPlanningApi extends Domain.Api("CoachPlanningApi", {
  model: Planning,
  commands: ["CreatePlan", "ConcretizeSession", "ReviseWeek"],
  views: [],
  streams: [],
}) {}
