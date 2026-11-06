import { AthleteId } from "@cadencia/kernel/Athlete.id";
import { Day } from "@cadencia/kernel/Day";
import { EvidenceSnapshot, Fingerprint } from "@cadencia/kernel/Evidence";
import { NotYours } from "@cadencia/kernel/NotYours.rejection";
import { Session } from "@cadencia/kernel/Session.middleware";
import { Workout } from "@cadencia/kernel/Workout";
import * as Domain from "@alchemy.run/domain";
import * as Schema from "effect/Schema";
import { CoachNote, InterpretedOn } from "../CoachShape.ts";
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
  attempt: Schema.Int,
  planId: Schema.String,
  workout: Workout,
  note: CoachNote,
  evidence: EvidenceSnapshot,
  model: Schema.String,
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
    planId: Schema.String,
    workout: Workout,
    note: CoachNote,
    evidence: EvidenceSnapshot,
    model: Schema.String,
    interpretedOn: InterpretedOn,
  },
  events: [DailyDecisionRecorded],
  rejects: [DecisionAlreadyAccepted, NotYours],
}) {}
