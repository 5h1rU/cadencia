import { EvidenceSnapshot, Fingerprint } from "@cadencia/athlete/Evidence";
import { AthleteId } from "@cadencia/identity/Athlete.id";
import { NotYours } from "@cadencia/identity/NotYours.rejection";
import { Session } from "@cadencia/identity/Session.middleware";
import { Day } from "@cadencia/kernel/Calendar/Day";
import { PlanId } from "@cadencia/kernel/Plan.id";
import { Workout } from "@cadencia/kernel/Training/Workout";
import * as Domain from "@alchemy.run/domain";
import { CoachNote } from "../CoachNote.ts";
import { InterpretedOn, ModelName } from "../Provenance.ts";
import { Attempt } from "./Attempt.ts";
import { DailyDecisionId } from "./DailyDecision.id.ts";

/** The plan already accepted a decision for this day from the same evidence. */
export class DecisionAlreadyAccepted extends Domain.Rejection(
  "DecisionAlreadyAccepted",
  { fingerprint: Fingerprint },
  { httpApiStatus: 409 },
) {}

export class DailyDecisionRecorded extends Domain.Event("DailyDecisionRecorded", {
  athleteId: AthleteId,
  day: Day,
  attempt: Attempt,
  planId: PlanId,
  workout: Workout,
  note: CoachNote,
  evidence: EvidenceSnapshot,
  model: ModelName,
  interpretedOn: InterpretedOn,
}) {}

/**
 * Record what the AI proposed for the day, with the evidence it used. The
 * Planning model then accepts or refuses it. Sent by the device that ran the AI.
 */
export class RecordDailyDecision extends Domain.Command("RecordDailyDecision", {
  target: DailyDecisionId,
  middleware: [Session],
  input: {
    planId: PlanId,
    workout: Workout,
    note: CoachNote,
    evidence: EvidenceSnapshot,
    model: ModelName,
    interpretedOn: InterpretedOn,
  },
  events: [DailyDecisionRecorded],
  rejects: [DecisionAlreadyAccepted, NotYours],
}) {}
