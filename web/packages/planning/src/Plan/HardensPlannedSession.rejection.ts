import { Day } from "@cadencia/kernel/Day";
import { SessionKind } from "@cadencia/kernel/SessionKind";
import * as Domain from "@alchemy.run/domain";
import * as Schema from "effect/Schema";

/** Readiness can soften a planned session, never harden it beyond the plan. */
export class HardensPlannedSession extends Domain.Rejection(
  "HardensPlannedSession",
  { day: Day, planned: SessionKind, proposed: SessionKind, peakIntensity: Schema.Number },
  { httpApiStatus: 422 },
) {}
