import * as Domain from "@alchemy.run/domain";
import { PlanAnswer, Refusal } from "../CoachShape.ts";
import { ConversationId } from "./Conversation.id.ts";
import { MessageId } from "./Message.id.ts";

export class IntentApplied extends Domain.Event("IntentApplied", { messageId: MessageId }) {}

export class IntentRefused extends Domain.Event("IntentRefused", { messageId: MessageId, refusal: Refusal }) {}

/** Record what the plan did with an accepted intent. Sent by `IntentApplier`; it never rejects. */
export class RecordIntentOutcome extends Domain.Command("RecordIntentOutcome", {
  target: ConversationId,
  input: { messageId: MessageId, answer: PlanAnswer },
  events: [IntentApplied, IntentRefused],
}) {}
