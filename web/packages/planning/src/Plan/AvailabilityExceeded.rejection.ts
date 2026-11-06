import { Day } from "@cadencia/kernel/Day";
import * as Domain from "@alchemy.run/domain";
import * as Schema from "effect/Schema";

/** More riding than the day allows: availability, time away, or the athlete's own limit. */
export class AvailabilityExceeded extends Domain.Rejection(
  "AvailabilityExceeded",
  { day: Day, allowedMinutes: Schema.Number, proposedMinutes: Schema.Number },
  { httpApiStatus: 422 },
) {}
