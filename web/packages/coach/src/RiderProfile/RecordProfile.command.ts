import { AthleteId } from "@cadencia/identity/Athlete.id";
import { NotYours } from "@cadencia/identity/NotYours.rejection";
import { Session } from "@cadencia/identity/Session.middleware";
import * as Domain from "@alchemy.run/domain";
import { InterpretedOn, ModelName } from "../Provenance.ts";
import { RiderReport } from "./RiderReport.ts";

export class ProfileRecorded extends Domain.Event("ProfileRecorded", {
  report: RiderReport,
  model: ModelName,
  interpretedOn: InterpretedOn,
}) {}

/** Record the profile the AI generated. */
export class RecordProfile extends Domain.Command("RecordProfile", {
  target: AthleteId,
  middleware: [Session],
  input: { report: RiderReport, model: ModelName, interpretedOn: InterpretedOn },
  events: [ProfileRecorded],
  rejects: [NotYours],
}) {}
