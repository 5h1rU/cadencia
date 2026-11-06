import { ownerOf } from "@cadencia/identity/Athlete.id";
import { NotYours } from "@cadencia/identity/NotYours.rejection";
import { mustOwn } from "@cadencia/identity/owns";
import { Session } from "@cadencia/identity/Session.middleware";
import * as Domain from "@alchemy.run/domain";
import * as Effect from "effect/Effect";
import * as Schema from "effect/Schema";
import { Refusal } from "../CoachShape.ts";
import { MessageText, ModelName } from "../CoachText.ts";
import { Conversation } from "./Conversation.aggregate.ts";
import { Intent, IntentStatus } from "./Intent.ts";
import { MessageId } from "./Message.id.ts";

export const ThreadMessage = Schema.Struct({
  messageId: MessageId,
  role: Schema.Literals(["athlete", "coach"]),
  text: MessageText,
  at: Schema.DateTimeUtc,
  intent: Schema.NullOr(Intent),
  intentStatus: Schema.NullOr(IntentStatus),
  refusal: Schema.NullOr(Refusal),
  model: Schema.NullOr(ModelName),
});
export type ThreadMessage = typeof ThreadMessage.Type;

type Thread = { readonly messages: ReadonlyArray<ThreadMessage> };

const update = (v: Thread, messageId: MessageId, change: Partial<ThreadMessage>): Thread => ({
  messages: v.messages.map((m) => (m.messageId === messageId ? { ...m, ...change } : m)),
});

/** A month of conversation, as both sides wrote it, with each intent and where it stands. */
export class ConversationThread extends Domain.View("ConversationThread", {
  from: [Conversation],
  key: Conversation,
  middleware: [Session],
  rejects: [NotYours],
  state: Schema.Struct({ messages: Schema.Array(ThreadMessage) }),
  initial: { messages: [] },
  evolve: {
    MessageSent: (v, e, { at }) => ({
      messages: [
        ...v.messages,
        {
          messageId: e.messageId,
          role: "athlete" as const,
          text: e.text,
          at,
          intent: null,
          intentStatus: null,
          refusal: null,
          model: null,
        },
      ],
    }),
    CoachReplied: (v, e, { at }) => ({
      messages: [
        ...v.messages,
        {
          messageId: e.messageId,
          role: "coach" as const,
          text: e.text,
          at,
          intent: e.intent,
          intentStatus: e.intent ? ("proposed" as const) : null,
          refusal: null,
          model: e.model,
        },
      ],
    }),
    IntentAccepted: (v, e) => update(v, e.messageId, { intentStatus: "accepted" }),
    IntentDismissed: (v, e) => update(v, e.messageId, { intentStatus: "dismissed" }),
    IntentApplied: (v, e) => update(v, e.messageId, { intentStatus: "applied" }),
    IntentRefused: (v, e) => update(v, e.messageId, { intentStatus: "refused", refusal: e.refusal }),
  },
  validate: Effect.fn(function* (request) {
    yield* mustOwn(ownerOf(request.key.id));
  }),
}) {}
