import { Day } from "@cadencia/kernel/Calendar/Day";
import { Minutes } from "@cadencia/kernel/Training/Units";
import * as Domain from "@alchemy.run/domain";

/** More riding than the day allows: availability, time away, or the athlete's own limit. */
export class AvailabilityExceeded extends Domain.Rejection(
  "AvailabilityExceeded",
  { day: Day, allowedMinutes: Minutes, proposedMinutes: Minutes },
  { httpApiStatus: 422 },
) {}
