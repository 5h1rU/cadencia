import { Authenticated } from "@cadencia/identity/Authenticated.middleware";
import { NotYours } from "@cadencia/identity/NotYours.rejection";
import * as Domain from "@alchemy.run/domain";
import { MessageText } from "../Conversation/MessageText.ts";
import { InterpretedOn, ModelName } from "../Provenance.ts";
import { ConsultationId } from "./Consultation.id.ts";
import { ConsultationNotOpen } from "./ConsultationNotOpen.rejection.ts";

export class CoachAsked extends Domain.Event("CoachAsked", {
  text: MessageText,
  model: ModelName,
  interpretedOn: InterpretedOn,
}) {}

/** Record the AI's next question. */
export class RecordCoachQuestion extends Domain.Command("RecordCoachQuestion", {
  target: ConsultationId,
  middleware: [Authenticated],
  input: { text: MessageText, model: ModelName, interpretedOn: InterpretedOn },
  events: [CoachAsked],
  rejects: [ConsultationNotOpen, NotYours],
}) {}
