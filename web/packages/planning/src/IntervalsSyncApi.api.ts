import * as Domain from "@alchemy.run/domain";
import { Planning } from "./Planning.model.ts";

/** What the Intervals sync reaches, in process: changes the athlete made in Intervals. */
export class IntervalsSyncApi extends Domain.Api("IntervalsSyncApi", {
  model: Planning,
  commands: ["RecordExternalChange"],
  views: [],
  streams: [],
}) {}
