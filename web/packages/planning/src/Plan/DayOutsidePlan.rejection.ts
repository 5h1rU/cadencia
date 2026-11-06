import { Day } from "@cadencia/kernel/Calendar/Day";
import * as Domain from "@alchemy.run/domain";

/** The day is outside the plan's dates. */
export class DayOutsidePlan extends Domain.Rejection(
  "DayOutsidePlan",
  { day: Day, startDay: Day, endDay: Day },
  { httpApiStatus: 422 },
) {}
