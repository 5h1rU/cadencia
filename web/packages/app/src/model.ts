import { ActivitySummary } from "@cadencia/athlete/ActivitySummary";
import { AthleteMeasures } from "@cadencia/athlete/AthleteMeasures";
import { WellnessDay } from "@cadencia/athlete/Wellness";
import { AcceptIntent } from "@cadencia/coach/Conversation/AcceptIntent.command";
import { ConversationId, conversationIdFor, monthOf } from "@cadencia/coach/Conversation/Conversation.id";
import { ThreadMessage } from "@cadencia/coach/Conversation/ConversationThread.view";
import { DismissIntent } from "@cadencia/coach/Conversation/DismissIntent.command";
import { TodayDecision } from "@cadencia/coach/DailyDecision/TodayDecision.view";
import { RiderProfileCard } from "@cadencia/coach/RiderProfile/RiderProfileCard.view";
import { AthleteId } from "@cadencia/identity/Athlete.id";
import { Day } from "@cadencia/kernel/Calendar/Day";
import { CurrentPlanState } from "@cadencia/planning/Plan/CurrentPlan.view";
import { MoveSession } from "@cadencia/planning/Plan/MoveSession.command";
import { RecordDayRequirement } from "@cadencia/planning/Plan/RecordDayRequirement.command";
import { RetirePlan } from "@cadencia/planning/Plan/RetirePlan.command";
import * as DomainFoldkit from "@alchemy.run/domain/Foldkit";
import * as Option from "effect/Option";
import * as Schema from "effect/Schema";
import { AsyncData } from "foldkit";
import { defineTaggedUnion } from "foldkit/schema";
import { DeclarationForm, MoveForm, RequirementForm } from "./domain/form.ts";
import { IntervalsProblem } from "./domain/intervalsProblem.ts";
import { AppRoute } from "./route.ts";

/** The views' own state schemas: the app keeps exactly what the domain shows. */
export const DecisionState = TodayDecision.State;
export const ProfileState = RiderProfileCard.State;

/** A month of conversation, with the id it was read under: an intent's answer goes back to it. */
export const Thread = Schema.Struct({ conversationId: ConversationId, messages: Schema.Array(ThreadMessage) });

/** The domain views the app watches live, each over its own WebSocket. */
export const LiveView = Schema.Literals(["plan", "decision", "thread", "profile"]);
export type LiveView = typeof LiveView.Type;

/** Why a live view can't be shown: the domain refused it to this athlete. */
export const ReadProblem = Schema.Literal("notYours");

/**
 * Each live view as the app holds it: not watched (signed out), waiting for its
 * first snapshot, the snapshot, or refused. A view that can be absent keeps
 * its `Option` as the data, so "no plan" is a snapshot, not a wait.
 */
export const LivePlan = AsyncData.Schema(Schema.Option(CurrentPlanState), ReadProblem);
export const LiveDecision = AsyncData.Schema(Schema.Option(DecisionState), ReadProblem);
export const LiveThread = AsyncData.Schema(Thread, ReadProblem);
export const LiveProfile = AsyncData.Schema(Schema.Option(ProfileState), ReadProblem);

/** What a domain command is sent with: the schemas of its target and its input. */
type Sendable = {
  readonly target: Schema.Top;
  readonly rpc: { readonly payloadSchema: { readonly fields: { readonly input: Schema.Top } } };
};

/** A write's fields, exactly as its domain command declares them: a change to the command reaches the app. */
const writeOf = <C extends Sendable>(
  command: C,
): { readonly target: C["target"]; readonly input: C["rpc"]["payloadSchema"]["fields"]["input"] } => ({
  target: command.target,
  input: command.rpc.payloadSchema.fields.input,
});

/**
 * A write the web sends, as the Api command's target and input. It is kept
 * while in flight, so an unknown outcome can be sent again unchanged.
 */
export const Write = defineTaggedUnion({
  AcceptIntent: writeOf(AcceptIntent),
  DismissIntent: writeOf(DismissIntent),
  MoveSession: writeOf(MoveSession),
  RecordDayRequirement: writeOf(RecordDayRequirement),
  RetirePlan: writeOf(RetirePlan),
});
export type Write = typeof Write.Type;

/** The write waiting for its outcome: `unknown` when it may or may not have been applied. */
export const InFlight = Schema.Struct({
  write: Write,
  commandId: Schema.String,
  outcome: Schema.Literals(["sending", "unknown"]),
});
export type InFlight = typeof InFlight.Type;

/** What Intervals.icu says about the athlete's last four weeks, read together for the history and the profile. */
export const IntervalsHistory = Schema.Struct({
  activities: Schema.Array(ActivitySummary),
  wellness: Schema.Array(WellnessDay),
  athlete: AthleteMeasures,
});
export type IntervalsHistory = typeof IntervalsHistory.Type;

/** The history as the app holds it: not asked for, loading, loaded, refreshing, or why it couldn't be read. */
export const History = AsyncData.Schema(IntervalsHistory, IntervalsProblem);
export type HistoryData = typeof History.schema.Type;

export const Flags = Schema.Struct({
  athleteId: Schema.NullOr(AthleteId),
  /** The server didn't say who is signed in. */
  unreachable: Schema.Boolean,
  today: Day,
  /** Names this load of the page: its commands' ids start with it. */
  pageLoad: Schema.String,
});
export type Flags = typeof Flags.Type;

export const Model = Schema.Struct({
  athleteId: Schema.NullOr(AthleteId),
  /** The app opened without learning who is signed in: nobody is shown as signed out until the server says so. */
  unreachable: Schema.Boolean,
  /** The athlete's local day; it advances at local midnight. */
  today: Day,
  route: AppRoute,
  commandIds: DomainFoldkit.CommandIds,
  /** Whether the live reads may run: false after a transport failure, until the backoff ends. */
  readsOnline: Schema.Boolean,
  /** Transport failures since the last read that worked, for the backoff. */
  readRetries: Schema.Number,
  plan: LivePlan.schema,
  decision: LiveDecision.schema,
  thread: LiveThread.schema,
  profile: LiveProfile.schema,
  history: History.schema,
  move: MoveForm,
  requirement: RequirementForm,
  declaration: DeclarationForm,
  savingDeclaration: Schema.Boolean,
  /** Intervals changed while a history read was under way: its answer may predate the change, so it is read again. */
  historyOutdated: Schema.Boolean,
  confirmRetire: Schema.Boolean,
  inFlight: Schema.Option(InFlight),
  /** Intervals.icu said the athlete's connection is gone: offer to connect again. */
  needsReconnect: Schema.Boolean,
  notice: Schema.Option(Schema.String),
  error: Schema.Option(Schema.String),
});
export type Model = typeof Model.Type;

const showsHistory = AppRoute.isAnyOf(["History", "Profile"]);

export const isSignedIn = (model: Model) => model.athleteId !== null;

/** A signed-in athlete is on a page that shows the history. */
export const historyOnScreen = (model: Model) => isSignedIn(model) && showsHistory(model.route);

/** Whether a write is waiting: every write control is disabled until it settles. */
export const busy = (model: Model) => Option.isSome(model.inFlight);

/**
 * Keys must be well-formed even before anyone signs in. This athlete id is
 * never read: every watch is disabled while signed out.
 */
export const NOBODY = AthleteId.make("i1");

export const ownerOf = (model: Model): AthleteId => model.athleteId ?? NOBODY;
export const conversationOf = (model: Model): ConversationId => conversationIdFor(ownerOf(model), monthOf(model.today));
