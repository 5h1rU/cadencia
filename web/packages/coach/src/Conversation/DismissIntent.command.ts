import { NotYours } from "@cadencia/identity/NotYours.rejection";
import { Session } from "@cadencia/identity/Session.middleware";
import * as Domain from "@alchemy.run/domain";
import { ConversationId } from "./Conversation.id.ts";
import { MessageId } from "./Message.id.ts";
import { NoOpenIntent } from "./NoOpenIntent.rejection.ts";

export class IntentDismissed extends Domain.Event("IntentDismissed", { messageId: MessageId }) {}

/** The athlete turns down the change the coach proposed. */
export class DismissIntent extends Domain.Command("DismissIntent", {
  target: ConversationId,
  middleware: [Session],
  input: { messageId: MessageId },
  events: [IntentDismissed],
  rejects: [NoOpenIntent, NotYours],
}) {}
