import { NotYours } from "@cadencia/kernel/NotYours.rejection";
import { Session } from "@cadencia/kernel/Session.middleware";
import * as Domain from "@alchemy.run/domain";
import * as Schema from "effect/Schema";
import { InterpretedOn } from "../CoachShape.ts";
import { ConversationId } from "./Conversation.id.ts";
import { Intent } from "./Intent.ts";

export class CoachReplied extends Domain.Event("CoachReplied", {
  messageId: Schema.String,
  inReplyTo: Schema.String,
  text: Schema.String,
  intent: Schema.NullOr(Intent),
  model: Schema.String,
  interpretedOn: InterpretedOn,
}) {}

/** Record the AI's reply to a message, and the change to the plan it proposes, if any. */
export class RecordCoachReply extends Domain.Command("RecordCoachReply", {
  target: ConversationId,
  middleware: [Session],
  input: {
    messageId: Schema.String,
    inReplyTo: Schema.String,
    text: Schema.String,
    intent: Schema.NullOr(Intent),
    model: Schema.String,
    interpretedOn: InterpretedOn,
  },
  events: [CoachReplied],
  rejects: [NotYours],
}) {}
