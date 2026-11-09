import { Authenticated } from "@cadencia/identity/Authenticated.middleware";
import { NotYours } from "@cadencia/identity/NotYours.rejection";
import * as Domain from "@alchemy.run/domain";
import * as Schema from "effect/Schema";
import { InterpretedOn, ModelName } from "../Provenance.ts";
import { ConversationId } from "./Conversation.id.ts";
import { Intent } from "./Intent.ts";
import { MessageId } from "./Message.id.ts";
import { MessageText } from "./MessageText.ts";
import { UnknownMessage } from "./UnknownMessage.rejection.ts";

export class CoachReplied extends Domain.Event("CoachReplied", {
  messageId: MessageId,
  inReplyTo: MessageId,
  text: MessageText,
  intent: Schema.NullOr(Intent),
  model: ModelName,
  interpretedOn: InterpretedOn,
}) {}

/** Record the AI's reply to a message, and the change to the plan it proposes, if any. */
export class RecordCoachReply extends Domain.Command("RecordCoachReply", {
  target: ConversationId,
  middleware: [Authenticated],
  input: {
    messageId: MessageId,
    inReplyTo: MessageId,
    text: MessageText,
    intent: Schema.NullOr(Intent),
    model: ModelName,
    interpretedOn: InterpretedOn,
  },
  events: [CoachReplied],
  rejects: [NotYours, UnknownMessage],
}) {}
