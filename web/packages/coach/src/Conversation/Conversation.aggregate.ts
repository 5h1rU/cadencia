import { ownerOf } from "@cadencia/identity/Athlete.id";
import { NotYours } from "@cadencia/identity/NotYours.rejection";
import { mustOwn } from "@cadencia/identity/owns";
import * as Domain from "@alchemy.run/domain";
import * as Effect from "effect/Effect";
import * as Schema from "effect/Schema";
import { inputOf } from "../inputOf.ts";
import { AcceptIntent, IntentAccepted, IntentExpired } from "./AcceptIntent.command.ts";
import { ConversationId } from "./Conversation.id.ts";
import { DismissIntent, IntentDismissed } from "./DismissIntent.command.ts";
import { Intent, IntentStatus } from "./Intent.ts";
import { MessageId } from "./Message.id.ts";
import { NoOpenIntent } from "./NoOpenIntent.rejection.ts";
import { CoachReplied, RecordCoachReply } from "./RecordCoachReply.command.ts";
import { IntentApplied, IntentRefused, RecordIntentOutcome } from "./RecordIntentOutcome.command.ts";
import { MessageSent, SendMessage } from "./SendMessage.command.ts";
import { UnknownMessage } from "./UnknownMessage.rejection.ts";

/** Who wrote a message: the athlete, or the coach's reply. */
const Author = Schema.Literals(["athlete", "coach"]);

/**
 * Only what decisions need: which messages exist and who wrote them, so each
 * id names one message, and the intents and where each stands. The thread
 * lives in a view.
 */
const ConversationState = Schema.Struct({
  /** Absent for a conversation recorded before messages were kept: its ids aren't checked. */
  messages: Schema.optional(Schema.Array(Schema.Struct({ messageId: MessageId, author: Author }))),
  intents: Schema.Array(Schema.Struct({ messageId: MessageId, intent: Intent, status: IntentStatus })),
});
type ConversationState = typeof ConversationState.Type;

const withStatus = (s: ConversationState, messageId: MessageId, status: IntentStatus): ConversationState => ({
  ...s,
  intents: s.intents.map((i) => (i.messageId === messageId ? { ...i, status } : i)),
});

const withMessage = (s: ConversationState, messageId: MessageId, author: typeof Author.Type): ConversationState =>
  s.messages === undefined ? s : { ...s, messages: [...s.messages, { messageId, author }] };

/** Whether the conversation already has a message with this id. */
const has = (s: ConversationState, messageId: MessageId) => s.messages?.some((m) => m.messageId === messageId) ?? false;

/** Whether a reply may answer this message: one the athlete sent here. */
const canReplyTo = (s: ConversationState, messageId: MessageId) =>
  s.messages === undefined || s.messages.some((m) => m.messageId === messageId && m.author === "athlete");

const openIntent = (s: ConversationState, messageId: MessageId) =>
  s.intents.find((i) => i.messageId === messageId && i.status === "proposed");

/** One month of conversation between an athlete and the coach. */
export class Conversation extends Domain.Aggregate("Conversation", {
  id: ConversationId,
  state: ConversationState,
  initial: { messages: [], intents: [] },
  commands: [SendMessage, RecordCoachReply, AcceptIntent, DismissIntent, RecordIntentOutcome],
  decide: {
    SendMessage: Effect.fn(function* (state, cmd, { id }) {
      const athleteId = ownerOf(id);
      yield* mustOwn(athleteId);
      // Message ids are minted by the device: the same id is the same message, sent again.
      if (has(state, cmd.messageId)) return [];
      return [new MessageSent({ athleteId, ...inputOf(cmd) })];
    }),
    RecordCoachReply: Effect.fn(function* (state, cmd, { id }) {
      yield* mustOwn(ownerOf(id));
      // An intent changes the athlete's own plan; the plan id names its athlete.
      if (cmd.intent !== null && ownerOf(cmd.intent.planId) !== ownerOf(id)) return yield* new NotYours();
      if (!canReplyTo(state, cmd.inReplyTo)) return yield* new UnknownMessage({ messageId: cmd.inReplyTo });
      // A reply recorded again keeps the first: its intent may already be answered.
      if (has(state, cmd.messageId)) return [];
      return [new CoachReplied(inputOf(cmd))];
    }),
    AcceptIntent: Effect.fn(function* (state, cmd, { id }) {
      yield* mustOwn(ownerOf(id));
      const open = openIntent(state, cmd.messageId);
      if (!open) return yield* new NoOpenIntent({ messageId: cmd.messageId });
      if (open.intent.limits.every((limit) => limit.day < cmd.today)) {
        return yield* new IntentExpired({ messageId: cmd.messageId });
      }
      return [new IntentAccepted({ messageId: cmd.messageId, intent: open.intent, today: cmd.today })];
    }),
    DismissIntent: Effect.fn(function* (state, cmd, { id }) {
      yield* mustOwn(ownerOf(id));
      if (!openIntent(state, cmd.messageId)) return yield* new NoOpenIntent({ messageId: cmd.messageId });
      return [new IntentDismissed({ messageId: cmd.messageId })];
    }),
    RecordIntentOutcome: (state, cmd) => {
      const intent = state.intents.find((i) => i.messageId === cmd.messageId && i.status === "accepted");
      if (!intent) return [];
      return cmd.answer._tag === "Accepted"
        ? [new IntentApplied({ messageId: cmd.messageId })]
        : [new IntentRefused({ messageId: cmd.messageId, refusal: cmd.answer.refusal })];
    },
  },
  evolve: {
    MessageSent: (s, e) => withMessage(s, e.messageId, "athlete"),
    CoachReplied: (s, e) => {
      const next = withMessage(s, e.messageId, "coach");
      return e.intent === null
        ? next
        : { ...next, intents: [...next.intents, { messageId: e.messageId, intent: e.intent, status: "proposed" as const }] };
    },
    IntentAccepted: (s, e) => withStatus(s, e.messageId, "accepted"),
    IntentDismissed: (s, e) => withStatus(s, e.messageId, "dismissed"),
    IntentApplied: (s, e) => withStatus(s, e.messageId, "applied"),
    IntentRefused: (s, e) => withStatus(s, e.messageId, "refused"),
  },
}) {}
