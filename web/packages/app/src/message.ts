import { HistoryRange } from "@cadencia/athlete/HistoryRange";
import { ConversationId } from "@cadencia/coach/Conversation/Conversation.id";
import { MessageId } from "@cadencia/coach/Conversation/Message.id";
import { Day } from "@cadencia/kernel/Calendar/Day";
import { CurrentPlanState } from "@cadencia/planning/Plan/CurrentPlan.view";
import * as Schema from "effect/Schema";
import { Navigation, Url } from "foldkit";
import { defineMessageUnion } from "foldkit/message";
import { CoachClient, PlanningClient } from "./client.ts";
import { IntervalsProblem } from "./domain/intervalsProblem.ts";
import { DecisionState, IntervalsHistory, LiveView, ProfileState, Thread } from "./model.ts";

export const Message = defineMessageUnion({
  ClickedLink: { request: Navigation.UrlRequest },
  ChangedUrl: { url: Url.Url },
  CompletedNavigateInternal: {},
  CompletedLoadPage: {},
  ChangedDay: { today: Day },
  ReceivedPlan: { plan: Schema.Option(CurrentPlanState) },
  ReceivedDecision: { decision: Schema.Option(DecisionState) },
  ReceivedThread: { thread: Thread },
  ReceivedProfile: { profile: Schema.Option(ProfileState) },
  RefusedRead: { view: LiveView },
  LostReads: {},
  ReconnectedReads: {},
  SignedOut: {},
  /** The app opened without reaching the server, and the athlete asks to try again. */
  ClickedRetryStart: {},
  /** The history for `range` was read, or why it wasn't: the range tells a late answer from the current one. */
  SettledLoadIntervals: { range: HistoryRange, result: Schema.Result(IntervalsHistory, IntervalsProblem) },
  ClickedAcceptIntent: { conversationId: ConversationId, messageId: MessageId },
  ClickedDismissIntent: { conversationId: ConversationId, messageId: MessageId },
  UpdatedMove: { field: Schema.Literals(["sessionId", "toDay"]), value: Schema.String },
  SubmittedMove: {},
  UpdatedRequirement: { field: Schema.Literals(["day", "maxMinutes", "instructions"]), value: Schema.String },
  SubmittedRequirement: {},
  ClickedRetire: {},
  ClickedConfirmRetire: {},
  ClickedCancelRetire: {},
  ClickedRetryWrite: {},
  ClickedForgetWrite: {},
  ReceivedPlanningResult: { result: PlanningClient.Message },
  ReceivedCoachResult: { result: CoachClient.Message },
  UpdatedDeclaration: {
    field: Schema.Literals(["mood", "motivation", "soreness", "fatigue", "weight", "comments"]),
    value: Schema.String,
  },
  SubmittedDeclaration: {},
  SavedDeclaration: {},
  FailedDeclaration: { problem: IntervalsProblem },
});
export type Message = typeof Message.Type;
