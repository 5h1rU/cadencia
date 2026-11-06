import { AthleteId } from "@cadencia/kernel/Athlete.id";
import { NotYours } from "@cadencia/kernel/NotYours.rejection";
import { mustOwn, ownerOf } from "@cadencia/kernel/owns";
import { Session } from "@cadencia/kernel/Session.middleware";
import * as Domain from "@alchemy.run/domain";
import * as DateTime from "effect/DateTime";
import * as Effect from "effect/Effect";
import * as Schema from "effect/Schema";
import { Conversation } from "./Conversation.aggregate.ts";
import { Intent, IntentStatus } from "./Intent.ts";

export const ThreadMessage = Schema.Struct({
  messageId: Schema.String,
  role: Schema.Literals(["athlete", "coach"]),
  text: Schema.String,
  at: Schema.String,
  intent: Schema.NullOr(Intent),
  intentStatus: Schema.NullOr(IntentStatus),
  refusal: Schema.NullOr(Schema.String),
  model: Schema.NullOr(Schema.String),
});
export type ThreadMessage = typeof ThreadMessage.Type;

type Thread = { readonly messages: ReadonlyArray<ThreadMessage> };

const update = (v: Thread, messageId: string, change: Partial<ThreadMessage>): Thread => ({
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
          at: DateTime.formatIso(at),
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
          at: DateTime.formatIso(at),
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
    IntentRefused: (v, e) => update(v, e.messageId, { intentStatus: "refused", refusal: e.reason }),
  },
  validate: Effect.fn(function* (request) {
    yield* mustOwn(AthleteId.make(ownerOf(request.key.id)));
  }),
}) {}
