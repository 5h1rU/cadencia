import * as Domain from "@alchemy.run/domain";
import { Planning } from "./Planning.model.ts";

/** What the Intervals sync reaches, in process, as its system actor: the plan, and changes the athlete made in Intervals. */
export class IntervalsSyncApi extends Domain.Api("IntervalsSyncApi", {
  model: Planning,
  commands: ["RecordExternalChange"],
  views: ["CurrentPlan"],
  streams: [],
}) {}
