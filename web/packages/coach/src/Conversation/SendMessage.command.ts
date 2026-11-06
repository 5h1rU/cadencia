import { AthleteId } from "@cadencia/kernel/Athlete.id";
import { NotYours } from "@cadencia/kernel/NotYours.rejection";
import { Session } from "@cadencia/kernel/Session.middleware";
import * as Domain from "@alchemy.run/domain";
import * as Schema from "effect/Schema";
import { ConversationId } from "./Conversation.id.ts";

export class MessageSent extends Domain.Event("MessageSent", {
  athleteId: AthleteId,
  messageId: Schema.String,
  text: Schema.String,
}) {}

/** The athlete writes to the coach. Sent from the device that will run the AI for the reply. */
export class SendMessage extends Domain.Command("SendMessage", {
  target: ConversationId,
  middleware: [Session],
  input: { messageId: Schema.String, text: Schema.String },
  events: [MessageSent],
  rejects: [NotYours],
}) {}
