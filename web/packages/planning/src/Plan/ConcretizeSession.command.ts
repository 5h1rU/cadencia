import { Day } from "@cadencia/kernel/Day";
import { EvidenceSnapshot, Fingerprint } from "@cadencia/kernel/Evidence";
import { NotYours } from "@cadencia/kernel/NotYours.rejection";
import { Session } from "@cadencia/kernel/Session.middleware";
import { SessionKind } from "@cadencia/kernel/SessionKind";
import { Workout } from "@cadencia/kernel/Workout";
import * as Domain from "@alchemy.run/domain";
import * as Schema from "effect/Schema";
import { AvailabilityExceeded } from "./AvailabilityExceeded.rejection.ts";
import { HardensPlannedSession } from "./HardensPlannedSession.rejection.ts";
import { PlanId } from "./Plan.id.ts";
import { PlanNotActive } from "./PlanNotActive.rejection.ts";
import { PlannedSession } from "./PlanShape.ts";

/** The plan has no session that day. */
export class DayNotPlanned extends Domain.Rejection("DayNotPlanned", { day: Day }, { httpApiStatus: 422 }) {}

/** Riding stays easy on and right after a confirmed hard gym or CrossFit session. */
export class IntensityAfterHardTraining extends Domain.Rejection(
  "IntensityAfterHardTraining",
  { day: Day, proposed: SessionKind, peakIntensity: Schema.Number },
  { httpApiStatus: 422 },
) {}

/** The workout's shape contradicts its stated purpose: a rest day with riding, a malformed opener. */
export class PurposeMismatch extends Domain.Rejection(
  "PurposeMismatch",
  { day: Day, reason: Schema.String },
  { httpApiStatus: 422 },
) {}

export class SessionConcretized extends Domain.Event("SessionConcretized", {
  session: PlannedSession,
  softened: Schema.Boolean,
  fingerprint: Fingerprint,
}) {}

/** Turn a planned day into a concrete workout, within the plan's limits. */
export class ConcretizeSession extends Domain.Command(
  "ConcretizeSession",
  {
    target: PlanId,
    middleware: [Session],
    input: { day: Day, workout: Workout, evidence: EvidenceSnapshot },
    events: [SessionConcretized],
    rejects: [
      PlanNotActive,
      DayNotPlanned,
      AvailabilityExceeded,
      IntensityAfterHardTraining,
      HardensPlannedSession,
      PurposeMismatch,
      NotYours,
    ],
  }
) {}
