import { Authenticated } from "@cadencia/identity/Authenticated.middleware";
import { NotYours } from "@cadencia/identity/NotYours.rejection";
import * as Domain from "@alchemy.run/domain";
import { MessageText } from "../Conversation/MessageText.ts";
import { ConsultationId } from "./Consultation.id.ts";
import { ConsultationNotOpen } from "./ConsultationNotOpen.rejection.ts";

export class AthleteAnswered extends Domain.Event("AthleteAnswered", { text: MessageText }) {}

/** The athlete answers. */
export class AnswerQuestion extends Domain.Command("AnswerQuestion", {
  target: ConsultationId,
  middleware: [Authenticated],
  input: { text: MessageText },
  events: [AthleteAnswered],
  rejects: [ConsultationNotOpen, NotYours],
}) {}
