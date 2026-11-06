import { NotYours } from "@cadencia/identity/NotYours.rejection";
import { Session } from "@cadencia/identity/Session.middleware";
import * as Domain from "@alchemy.run/domain";
import { ConversationId } from "./Conversation.id.ts";
import { Intent } from "./Intent.ts";
import { MessageId } from "./Message.id.ts";
import { NoOpenIntent } from "./NoOpenIntent.rejection.ts";

export class IntentAccepted extends Domain.Event("IntentAccepted", {
  messageId: MessageId,
  intent: Intent,
}) {}

/** The athlete accepts the change the coach proposed. Needs no AI: the web can send it. */
export class AcceptIntent extends Domain.Command("AcceptIntent", {
  target: ConversationId,
  middleware: [Session],
  input: { messageId: MessageId },
  events: [IntentAccepted],
  rejects: [NoOpenIntent, NotYours],
}) {}
