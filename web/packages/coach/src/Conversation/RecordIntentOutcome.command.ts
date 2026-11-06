import * as Domain from "@alchemy.run/domain";
import * as Schema from "effect/Schema";
import { ConversationId } from "./Conversation.id.ts";

export class IntentApplied extends Domain.Event("IntentApplied", { messageId: Schema.String }) {}

export class IntentRefused extends Domain.Event("IntentRefused", {
  messageId: Schema.String,
  reason: Schema.String,
}) {}

/** Record what the plan did with an accepted intent. Sent by `IntentApplier`; it never rejects. */
export class RecordIntentOutcome extends Domain.Command("RecordIntentOutcome", {
  target: ConversationId,
  input: { messageId: Schema.String, accepted: Schema.Boolean, reason: Schema.NullOr(Schema.String) },
  events: [IntentApplied, IntentRefused],
}) {}
