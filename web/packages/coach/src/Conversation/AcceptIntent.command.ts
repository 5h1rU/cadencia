import { NotYours } from "@cadencia/identity/NotYours.rejection";
import { Session } from "@cadencia/identity/Session.middleware";
import { Day } from "@cadencia/kernel/Calendar/Day";
import * as Domain from "@alchemy.run/domain";
import { ConversationId } from "./Conversation.id.ts";
import { Intent } from "./Intent.ts";
import { MessageId } from "./Message.id.ts";
import { NoOpenIntent } from "./NoOpenIntent.rejection.ts";

/** Every day the intent is about is already past for the athlete: there is nothing left to change. */
export class IntentExpired extends Domain.Rejection("IntentExpired", { messageId: MessageId }, { httpApiStatus: 409 }) {}

export class IntentAccepted extends Domain.Event("IntentAccepted", {
  messageId: MessageId,
  intent: Intent,
  /** The athlete's local day when they accepted: days before it are past and stay as they are. */
  today: Day,
}) {}

/** The athlete accepts the change the coach proposed. Needs no AI: the web can send it. */
export class AcceptIntent extends Domain.Command("AcceptIntent", {
  target: ConversationId,
  middleware: [Session],
  input: { messageId: MessageId, today: Day },
  events: [IntentAccepted],
  rejects: [NoOpenIntent, IntentExpired, NotYours],
}) {}
