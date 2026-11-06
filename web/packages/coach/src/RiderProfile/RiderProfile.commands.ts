import { AthleteId } from "@cadencia/kernel/Athlete.id";
import { NotYours } from "@cadencia/kernel/NotYours.rejection";
import { Session } from "@cadencia/kernel/Session.middleware";
import * as Domain from "@alchemy.run/domain";
import * as Schema from "effect/Schema";
import { InterpretedOn } from "../CoachShape.ts";
import { RiderReport } from "./RiderReport.ts";

/** An automatic generation already ran once; only an explicit request may spend another. */
export class AutomaticAttemptUsed extends Domain.Rejection("AutomaticAttemptUsed", {}, { httpApiStatus: 409 }) {}

export class ProfileAttempted extends Domain.Event("ProfileAttempted", { automatic: Schema.Boolean }) {}
export class ProfileRecorded extends Domain.Event("ProfileRecorded", {
  report: RiderReport,
  model: Schema.String,
  interpretedOn: InterpretedOn,
}) {}
export class FtpProposalDismissed extends Domain.Event("FtpProposalDismissed", { ftp: Schema.Int }) {}

/**
 * Record that a device is about to ask the AI for a profile, before any network
 * work, so no device spends a second automatic generation.
 */
export class RecordProfileAttempt extends Domain.Command("RecordProfileAttempt", {
  target: AthleteId,
  middleware: [Session],
  input: { automatic: Schema.Boolean },
  events: [ProfileAttempted],
  rejects: [AutomaticAttemptUsed, NotYours],
}) {}

/** Record the profile the AI generated. */
export class RecordProfile extends Domain.Command("RecordProfile", {
  target: AthleteId,
  middleware: [Session],
  input: { report: RiderReport, model: Schema.String, interpretedOn: InterpretedOn },
  events: [ProfileRecorded],
  rejects: [NotYours],
}) {}

/** The athlete turns down an FTP the coach proposed. Needs no AI. */
export class DismissFtpProposal extends Domain.Command("DismissFtpProposal", {
  target: AthleteId,
  middleware: [Session],
  input: { ftp: Schema.Int },
  events: [FtpProposalDismissed],
  rejects: [NotYours],
}) {}
