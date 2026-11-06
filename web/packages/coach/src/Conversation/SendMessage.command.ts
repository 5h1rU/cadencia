import { AthleteId } from "@cadencia/identity/Athlete.id";
import { NotYours } from "@cadencia/identity/NotYours.rejection";
import { Session } from "@cadencia/identity/Session.middleware";
import * as Domain from "@alchemy.run/domain";
import { MessageText } from "../CoachText.ts";
import { ConversationId } from "./Conversation.id.ts";
import { MessageId } from "./Message.id.ts";

export class MessageSent extends Domain.Event("MessageSent", {
  athleteId: AthleteId,
  messageId: MessageId,
  text: MessageText,
}) {}

/** The athlete writes to the coach. Sent from the device that will run the AI for the reply. */
export class SendMessage extends Domain.Command("SendMessage", {
  target: ConversationId,
  middleware: [Session],
  input: { messageId: MessageId, text: MessageText },
  events: [MessageSent],
  rejects: [NotYours],
}) {}
