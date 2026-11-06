import { NotYours } from "@cadencia/kernel/NotYours.rejection";
import { Session } from "@cadencia/kernel/Session.middleware";
import * as Domain from "@alchemy.run/domain";
import * as Schema from "effect/Schema";
import { ConversationId } from "./Conversation.id.ts";
import { Intent } from "./Intent.ts";
import { NoOpenIntent } from "./NoOpenIntent.rejection.ts";

export class IntentAccepted extends Domain.Event("IntentAccepted", {
  messageId: Schema.String,
  intent: Intent,
}) {}

/** The athlete accepts the change the coach proposed. Needs no AI: the web can send it. */
export class AcceptIntent extends Domain.Command("AcceptIntent", {
  target: ConversationId,
  middleware: [Session],
  input: { messageId: Schema.String },
  events: [IntentAccepted],
  rejects: [NoOpenIntent, NotYours],
}) {}
