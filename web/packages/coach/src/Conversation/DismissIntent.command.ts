import { NotYours } from "@cadencia/kernel/NotYours.rejection";
import { Session } from "@cadencia/kernel/Session.middleware";
import * as Domain from "@alchemy.run/domain";
import * as Schema from "effect/Schema";
import { ConversationId } from "./Conversation.id.ts";
import { NoOpenIntent } from "./NoOpenIntent.rejection.ts";

export class IntentDismissed extends Domain.Event("IntentDismissed", { messageId: Schema.String }) {}

/** The athlete turns down the change the coach proposed. */
export class DismissIntent extends Domain.Command("DismissIntent", {
  target: ConversationId,
  middleware: [Session],
  input: { messageId: Schema.String },
  events: [IntentDismissed],
  rejects: [NoOpenIntent, NotYours],
}) {}
