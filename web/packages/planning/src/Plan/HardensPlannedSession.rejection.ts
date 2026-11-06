import { Day } from "@cadencia/kernel/Calendar/Day";
import { SessionKind } from "@cadencia/kernel/Training/SessionKind";
import { FtpFraction } from "@cadencia/kernel/Training/Units";
import * as Domain from "@alchemy.run/domain";

/** Readiness can soften a planned session, never harden it beyond the plan. */
export class HardensPlannedSession extends Domain.Rejection(
  "HardensPlannedSession",
  { day: Day, planned: SessionKind, proposed: SessionKind, peakIntensity: FtpFraction },
  { httpApiStatus: 422 },
) {}
