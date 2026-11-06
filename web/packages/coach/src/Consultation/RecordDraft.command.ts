import { NotYours } from "@cadencia/identity/NotYours.rejection";
import { Session } from "@cadencia/identity/Session.middleware";
import * as Domain from "@alchemy.run/domain";
import { InterpretedOn } from "../CoachShape.ts";
import { ModelName } from "../CoachText.ts";
import { ConsultationId } from "./Consultation.id.ts";
import { ConsultationNotOpen } from "./ConsultationNotOpen.rejection.ts";
import { PlanDraft } from "./PlanDraft.ts";

export class DraftProposed extends Domain.Event("DraftProposed", {
  draft: PlanDraft,
  model: ModelName,
  interpretedOn: InterpretedOn,
}) {}

/** Record the plan the AI drafted from the answers. */
export class RecordDraft extends Domain.Command("RecordDraft", {
  target: ConsultationId,
  middleware: [Session],
  input: { draft: PlanDraft, model: ModelName, interpretedOn: InterpretedOn },
  events: [DraftProposed],
  rejects: [ConsultationNotOpen, NotYours],
}) {}
