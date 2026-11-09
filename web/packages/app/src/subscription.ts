import { ConversationId, conversationIdFor, monthOf } from "@cadencia/coach/Conversation/Conversation.id";
import { dailyDecisionIdFor } from "@cadencia/coach/DailyDecision/DailyDecision.id";
import type { Unauthorized } from "@cadencia/identity/Authenticated.middleware";
import type { NotYours } from "@cadencia/identity/NotYours.rejection";
import { Day } from "@cadencia/kernel/Calendar/Day";
import * as Duration from "effect/Duration";
import * as Effect from "effect/Effect";
import * as Match from "effect/Match";
import * as Option from "effect/Option";
import type * as RpcClientError from "effect/rpc/RpcClientError";
import * as Stream from "effect/Stream";
import { Subscription } from "foldkit";
import { type Clients, CoachClient, PlanningClient } from "./client.ts";
import { Message } from "./message.ts";
import { conversationOf, LiveView, Model, NOBODY, ownerOf } from "./model.ts";

/** Live reads run while signed in, unless they are waiting out a transport failure. */
const reading = (model: Model) => model.athleteId !== null && model.readsOnline;

type ReadFailure = NotYours | Unauthorized | RpcClientError.RpcClientError;

/** A live view's read ended: signed out, refused to this athlete, or the connection dropped. */
export const readFailed =
  (view: LiveView) =>
  (error: ReadFailure): Message =>
    Match.valueTags(error, {
      Unauthorized: () => Message.SignedOut(),
      NotYours: () => Message.RefusedRead({ view }),
      RpcClientError: () => Message.LostReads(),
    });

const lostReads = (): Message => Message.LostReads();

/** Today's local day of a moment, as `YYYY-MM-DD`. */
export const localDayOf = (date: Date): Day =>
  Day.make(
    `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}-${String(date.getDate()).padStart(2, "0")}`,
  );

/** The wait until just after the next local midnight. */
export const untilNextMidnight = (now: Date): Duration.Duration =>
  Duration.millis(new Date(now.getFullYear(), now.getMonth(), now.getDate() + 1).getTime() - now.getTime() + 1000);

/**
 * The local day, looked at after each local midnight and whenever the page
 * comes back into view (a sleeping laptop misses its timers).
 */
const localDays: Stream.Stream<Day> = Stream.suspend(() =>
  Stream.merge(
    Stream.fromEffectRepeat(Effect.suspend(() => Effect.sleep(untilNextMidnight(new Date())))),
    Stream.merge(Stream.fromEventListener(document, "visibilitychange"), Stream.fromEventListener(window, "focus")),
  ),
).pipe(Stream.map(() => localDayOf(new Date())));

/** The thread of one conversation, its messages tagged with that conversation's id. */
const threadWatch = (conversationId: ConversationId) =>
  CoachClient.ConversationThread.watch({
    key: (_: Model) => conversationId,
    toMessage: ({ state }): Message =>
      Message.ReceivedThread({
        thread: { conversationId, messages: Option.match(state, { onNone: () => [], onSome: (t) => t.messages }) },
      }),
    onFailure: readFailed("thread"),
    onDefect: lostReads,
  });

export const subscriptions = Subscription.make<Model, Message, Clients>()((entry) => ({
  today: entry(
    { today: Day },
    {
      modelToDependencies: (model) => ({ today: model.today }),
      dependenciesToStream: ({ today }) =>
        localDays.pipe(
          Stream.filter((day) => day !== today),
          Stream.take(1),
          Stream.map((day): Message => Message.ChangedDay({ today: day })),
        ),
    },
  ),
  plan: PlanningClient.CurrentPlan.watch({
    key: ownerOf,
    isEnabled: reading,
    toMessage: ({ state }): Message =>
      Message.ReceivedPlan({ plan: Option.filter(state, (p) => p.planId !== null) }),
    onFailure: readFailed("plan"),
    onDefect: lostReads,
  }),
  decision: CoachClient.TodayDecision.watch({
    key: (model: Model) => dailyDecisionIdFor(ownerOf(model), model.today),
    isEnabled: reading,
    toMessage: ({ state }): Message => Message.ReceivedDecision({ decision: state }),
    onFailure: readFailed("decision"),
    onDefect: lostReads,
  }),
  // The watch is rebuilt for each conversation, so every snapshot names the
  // conversation it came from; only its dependency schema is taken from this one.
  thread: {
    ...threadWatch(conversationIdFor(NOBODY, monthOf(Day.make("2000-01-01")))),
    modelToDependencies: (model: Model) => ({ key: conversationOf(model), isEnabled: reading(model) }),
    dependenciesToStream: (dependencies) => threadWatch(dependencies.key).dependenciesToStream(dependencies),
  },
  profile: CoachClient.RiderProfileCard.watch({
    key: ownerOf,
    isEnabled: reading,
    toMessage: ({ state }): Message => Message.ReceivedProfile({ profile: state }),
    onFailure: readFailed("profile"),
    onDefect: lostReads,
  }),
}));
