import { ActivitySummary } from "@cadencia/athlete/ActivitySummary";
import { AthleteMeasures } from "@cadencia/athlete/AthleteMeasures";
import { HistoryRange } from "@cadencia/athlete/HistoryRange";
import { WellnessDay, WellnessDeclaration } from "@cadencia/athlete/Wellness";
import { AthleteCoachApi } from "@cadencia/coach/AthleteCoachApi.api";
import { ConversationId, conversationIdFor, monthOf } from "@cadencia/coach/Conversation/Conversation.id";
import { ThreadMessage } from "@cadencia/coach/Conversation/ConversationThread.view";
import { MessageId } from "@cadencia/coach/Conversation/Message.id";
import { dailyDecisionIdFor } from "@cadencia/coach/DailyDecision/DailyDecision.id";
import { TodayDecision } from "@cadencia/coach/DailyDecision/TodayDecision.view";
import type { RefusalReason } from "@cadencia/coach/Refusal";
import { RiderProfileCard } from "@cadencia/coach/RiderProfile/RiderProfileCard.view";
import { AthleteId } from "@cadencia/identity/Athlete.id";
import type { NotYours } from "@cadencia/identity/NotYours.rejection";
import type { Unauthorized } from "@cadencia/identity/Session.middleware";
import { addDays, Day } from "@cadencia/kernel/Calendar/Day";
import { PlanId } from "@cadencia/kernel/Plan.id";
import { Paragraph } from "@cadencia/kernel/Text";
import type { SessionKind } from "@cadencia/kernel/Training/SessionKind";
import { Minutes } from "@cadencia/kernel/Training/Units";
import { totalMinutes, type Workout } from "@cadencia/kernel/Training/Workout";
import { AthletePlanningApi } from "@cadencia/planning/AthletePlanningApi.api";
import type { CalendarProblem } from "@cadencia/planning/Plan/Calendar.external";
import { CurrentPlanState } from "@cadencia/planning/Plan/CurrentPlan.view";
import type { PlannedSession, SessionStatus } from "@cadencia/planning/Plan/PlannedSession";
import { SessionId } from "@cadencia/planning/Plan/Session.id";
import type * as Domain from "@alchemy.run/domain";
import * as DomainFoldkit from "@alchemy.run/domain/Foldkit";
import * as Duration from "effect/Duration";
import * as Effect from "effect/Effect";
import * as Data from "effect/Data";
import * as HttpClient from "effect/http/HttpClient";
import * as HttpClientRequest from "effect/http/HttpClientRequest";
import * as HttpClientResponse from "effect/http/HttpClientResponse";
import * as Option from "effect/Option";
import * as Result from "effect/Result";
import type * as RpcClientError from "effect/rpc/RpcClientError";
import * as Schema from "effect/Schema";
import * as Stream from "effect/Stream";
import { AsyncData, Command, Http, Subscription, type Update } from "foldkit";
import type { Document, Html, HtmlBuilder } from "foldkit/html";
import { defineMessageUnion } from "foldkit/message";
import { defineTaggedUnion } from "foldkit/schema";
import { modifyFields } from "foldkit/struct";

type Clients = Domain.Api.ClientKey<"AthletePlanningApi"> | Domain.Api.ClientKey<"AthleteCoachApi">;
export const PlanningClient = DomainFoldkit.make(AthletePlanningApi);
export const CoachClient = DomainFoldkit.make(AthleteCoachApi);

// MODEL

export const Section = Schema.Literals(["home", "coach", "plan", "history", "profile"]);
export type Section = typeof Section.Type;

/** The views' own state schemas: the app keeps exactly what the domain shows. */
const DecisionState = TodayDecision.State;
const ProfileState = RiderProfileCard.State;

/** A month of conversation, with the id it was read under: an intent's answer goes back to it. */
const Thread = Schema.Struct({ conversationId: ConversationId, messages: Schema.Array(ThreadMessage) });

/**
 * A write the web sends, as the Api command's target and input. It is kept
 * while in flight, so an unknown outcome can be sent again unchanged.
 */
export const Write = defineTaggedUnion({
  AcceptIntent: { target: ConversationId, input: Schema.Struct({ messageId: MessageId, today: Day }) },
  DismissIntent: { target: ConversationId, input: Schema.Struct({ messageId: MessageId }) },
  MoveSession: { target: PlanId, input: Schema.Struct({ sessionId: SessionId, toDay: Day }) },
  RecordDayRequirement: {
    target: PlanId,
    input: Schema.Struct({ day: Day, instructions: Paragraph, maxMinutes: Schema.NullOr(Minutes) }),
  },
  RetirePlan: { target: PlanId, input: Schema.Struct({ today: Day }) },
});
export type Write = typeof Write.Type;

/** The write waiting for its outcome: `unknown` when it may or may not have been applied. */
export const InFlight = Schema.Struct({
  write: Write,
  commandId: Schema.String,
  outcome: Schema.Literals(["sending", "unknown"]),
});
export type InFlight = typeof InFlight.Type;

/** Why an Intervals.icu read or write didn't happen. */
export const IntervalsProblem = Schema.Literals(["signedOut", "notConnected", "unavailable"]);
export type IntervalsProblem = typeof IntervalsProblem.Type;

/** What Intervals.icu says about the athlete's last four weeks, read together for the history and the profile. */
export const IntervalsHistory = Schema.Struct({
  activities: Schema.Array(ActivitySummary),
  wellness: Schema.Array(WellnessDay),
  athlete: AthleteMeasures,
});
export type IntervalsHistory = typeof IntervalsHistory.Type;

/** The history as the app holds it: not asked for, loading, loaded, refreshing, or why it couldn't be read. */
export const History = AsyncData.Schema(IntervalsHistory, IntervalsProblem);

/**
 * The day's declaration as the form holds it: what the athlete typed, not yet
 * checked. It is decoded into `WellnessDeclaration` when they save it.
 */
const Declaration = Schema.Struct({
  mood: Schema.String,
  motivation: Schema.String,
  soreness: Schema.String,
  fatigue: Schema.String,
  weight: Schema.String,
  comments: Schema.String,
});
type Declaration = typeof Declaration.Type;
const emptyDeclaration: Declaration = { mood: "", motivation: "", soreness: "", fatigue: "", weight: "", comments: "" };

export const Flags = Schema.Struct({
  athleteId: Schema.NullOr(AthleteId),
  today: Day,
  session: Schema.String,
});
export type Flags = typeof Flags.Type;

export const Model = Schema.Struct({
  athleteId: Schema.NullOr(AthleteId),
  /** The athlete's local day; it advances at local midnight. */
  today: Day,
  section: Section,
  commandIds: DomainFoldkit.CommandIds,
  /** Whether the live reads may run: false after a transport failure, until the backoff ends. */
  readsOnline: Schema.Boolean,
  /** Transport failures since the last read that worked, for the backoff. */
  readRetries: Schema.Number,
  plan: Schema.Option(CurrentPlanState),
  decision: Schema.Option(DecisionState),
  thread: Schema.Option(Thread),
  profile: Schema.Option(ProfileState),
  history: History.schema,
  move: Schema.Struct({ sessionId: Schema.String, toDay: Schema.String }),
  requirement: Schema.Struct({ day: Schema.String, maxMinutes: Schema.String, instructions: Schema.String }),
  declaration: Declaration,
  savingDeclaration: Schema.Boolean,
  confirmRetire: Schema.Boolean,
  inFlight: Schema.Option(InFlight),
  /** Intervals.icu said the athlete's connection is gone: offer to connect again. */
  needsReconnect: Schema.Boolean,
  notice: Schema.Option(Schema.String),
  error: Schema.Option(Schema.String),
});
export type Model = typeof Model.Type;

// MESSAGE

export const Message = defineMessageUnion({
  ClickedSection: { section: Section },
  ChangedDay: { today: Day },
  ReceivedPlan: { plan: Schema.Option(CurrentPlanState) },
  ReceivedDecision: { decision: Schema.Option(DecisionState) },
  ReceivedThread: { thread: Thread },
  ReceivedProfile: { profile: Schema.Option(ProfileState) },
  RefusedRead: {},
  LostReads: {},
  ReconnectedReads: {},
  SignedOut: {},
  /** The history for `range` was read, or why it wasn't: the range tells a late answer from the current one. */
  SettledLoadIntervals: { range: HistoryRange, result: Schema.Result(IntervalsHistory, IntervalsProblem) },
  ClickedAcceptIntent: { conversationId: ConversationId, messageId: MessageId },
  ClickedDismissIntent: { conversationId: ConversationId, messageId: MessageId },
  ChangedMove: { field: Schema.Literals(["sessionId", "toDay"]), value: Schema.String },
  SubmittedMove: {},
  ChangedRequirement: { field: Schema.Literals(["day", "maxMinutes", "instructions"]), value: Schema.String },
  SubmittedRequirement: {},
  ClickedRetire: {},
  ClickedConfirmRetire: {},
  ClickedCancelRetire: {},
  ClickedRetryWrite: {},
  ClickedForgetWrite: {},
  ReceivedPlanningResult: { result: PlanningClient.Message },
  ReceivedCoachResult: { result: CoachClient.Message },
  ChangedDeclaration: {
    field: Schema.Literals(["mood", "motivation", "soreness", "fatigue", "weight", "comments"]),
    value: Schema.String,
  },
  SubmittedDeclaration: {},
  SavedDeclaration: {},
  FailedDeclaration: { problem: IntervalsProblem },
});
export type Message = typeof Message.Type;

// COMMAND

/** The domain command for a write, its result mapped back into the app. */
export const commandFor = (write: Write, commandId: string): Command.Command<Message, never, Clients> => {
  const planning = (result: typeof PlanningClient.Message.Type): Message => Message.ReceivedPlanningResult({ result });
  const coach = (result: typeof CoachClient.Message.Type): Message => Message.ReceivedCoachResult({ result });
  return Write.match<Command.Command<Message, never, Clients>>(write, {
    AcceptIntent: ({ target, input }) => Command.mapMessage(CoachClient.AcceptIntent({ target, input, commandId }), coach),
    DismissIntent: ({ target, input }) => Command.mapMessage(CoachClient.DismissIntent({ target, input, commandId }), coach),
    MoveSession: ({ target, input }) => Command.mapMessage(PlanningClient.MoveSession({ target, input, commandId }), planning),
    RecordDayRequirement: ({ target, input }) =>
      Command.mapMessage(PlanningClient.RecordDayRequirement({ target, input, commandId }), planning),
    RetirePlan: ({ target, input }) => Command.mapMessage(PlanningClient.RetirePlan({ target, input, commandId }), planning),
  });
};

/**
 * What a failed Intervals.icu call means to the athlete, by the status the
 * server declares for it: 401 signed out, 409 Intervals not connected any
 * more, anything else Intervals not answering.
 */
export const intervalsProblemOf = (status: number): IntervalsProblem =>
  status === 401 ? "signedOut" : status === 409 ? "notConnected" : "unavailable";

/** A failed call, by its status; one that never got an answer is Intervals not answering. */
class IntervalsFailed extends Data.TaggedError("IntervalsFailed")<{ readonly problem: IntervalsProblem }> {}

const answered = (response: HttpClientResponse.HttpClientResponse) =>
  response.status >= 200 && response.status < 300
    ? Effect.succeed(response)
    : Effect.fail(new IntervalsFailed({ problem: intervalsProblemOf(response.status) }));

/** One of the server's Intervals reads, decoded with the read model `@cadencia/athlete` declares for it. */
const readIntervals = <S extends Schema.ConstraintDecoder<unknown>>(schema: S, path: string, range?: HistoryRange) =>
  HttpClient.get(path, range === undefined ? undefined : { urlParams: range }).pipe(
    Effect.flatMap(answered),
    Effect.flatMap(HttpClientResponse.schemaBodyJson(schema)),
  );

const problemOf = (error: unknown): IntervalsProblem => (error instanceof IntervalsFailed ? error.problem : "unavailable");

export const LoadIntervals = Command.define("LoadIntervals", {
  args: { range: HistoryRange },
  messages: [Message.SettledLoadIntervals],
  execute: ({ range }) =>
    Effect.all(
      {
        activities: readIntervals(Schema.Array(ActivitySummary), "/api/intervals/activities", range),
        wellness: readIntervals(Schema.Array(WellnessDay), "/api/intervals/wellness", range),
        athlete: readIntervals(AthleteMeasures, "/api/intervals/athlete"),
      },
      { concurrency: "unbounded" },
    ).pipe(
      Effect.mapError(problemOf),
      Effect.result,
      Effect.map((result) => Message.SettledLoadIntervals({ range, result })),
      Effect.provide(Http.layer),
    ),
});

export const SaveDeclaration = Command.define("SaveDeclaration", {
  args: { day: Day, declaration: WellnessDeclaration },
  messages: [Message.SavedDeclaration, Message.FailedDeclaration],
  execute: ({ day, declaration }) =>
    HttpClientRequest.put(`/api/intervals/wellness/${day}`).pipe(
      HttpClientRequest.schemaBodyJson(WellnessDeclaration)(declaration),
      Effect.flatMap(HttpClient.execute),
      Effect.flatMap(answered),
      Effect.as(Message.SavedDeclaration()),
      Effect.catch((error) => Effect.succeed(Message.FailedDeclaration({ problem: problemOf(error) }))),
      Effect.provide(Http.layer),
    ),
});

/** Seconds to wait before reading again after `retries` transport failures in a row. */
export const backoffSeconds = (retries: number) => Math.min(60, 2 ** retries);

export const WaitToReconnect = Command.define("WaitToReconnect", {
  args: { seconds: Schema.Number },
  messages: [Message.ReconnectedReads],
  execute: ({ seconds }) => Effect.sleep(Duration.seconds(seconds)).pipe(Effect.as(Message.ReconnectedReads())),
});

/** What the wellness form becomes once decoded: empty fields are left out; anything else must be valid. */
export const declarationOf = (form: Declaration) => {
  const number = (value: string) => (value.trim() === "" ? undefined : Number(value));
  return Schema.decodeUnknownOption(WellnessDeclaration)(
    Object.fromEntries(
      Object.entries({
        mood: number(form.mood),
        motivation: number(form.motivation),
        soreness: number(form.soreness),
        fatigue: number(form.fatigue),
        weight: number(form.weight),
        comments: form.comments.trim() === "" ? undefined : form.comments.trim(),
      }).filter(([, v]) => v !== undefined),
    ),
  );
};

/** The four weeks of history the web shows. */
const historyOf = (today: Day): HistoryRange => ({ oldest: addDays(today, -27), newest: today });

// UPDATE

type PlanningResult = typeof PlanningClient.Message.Type;
type CoachResult = typeof CoachClient.Message.Type;
/** The rejections a command's derived result can carry. */
type RejectionOf<Result, Tag extends string> =
  Extract<Result, { readonly _tag: Tag }> extends { readonly failure: infer F }
    ? F extends { readonly _tag: "Rejected"; readonly rejection: infer R }
      ? R
      : never
    : never;

/** One text per rejection a command declares: adding a rejection to the domain fails the build here. */
type Explanations<R extends { readonly _tag: string }> = {
  readonly [T in R["_tag"]]: (rejection: Extract<R, { readonly _tag: T }>) => string;
};

const explain =
  <R extends { readonly _tag: string }>(texts: Explanations<R>) =>
  (rejection: R): string =>
    (texts[rejection._tag as R["_tag"]] as (r: R) => string)(rejection);

const notYours = () => "Esto pertenece a otra cuenta. Vuelve a entrar con la tuya de Intervals.icu.";
const planNotActive = () => "El plan ya no está activo.";
const dayOutsidePlan = ({ startDay, endDay }: { readonly startDay: Day; readonly endDay: Day }) =>
  `Ese día está fuera del plan (${startDay} → ${endDay}).`;
const noOpenIntent = () => "Esa propuesta ya no está pendiente.";

export const MOVE_REJECTIONS: Explanations<RejectionOf<PlanningResult, "FailedMoveSession">> = {
  PlanNotActive: planNotActive,
  SessionNotFound: () => "Esa sesión ya no existe en el plan.",
  SessionNotMovable: ({ status }) =>
    status === "skipped"
      ? "Esa sesión se omitió porque ese día no tenías disponibilidad: ya no se puede mover."
      : "Esa sesión la cambiaste en Intervals.icu, que manda: muévela allí.",
  DayOutsidePlan: dayOutsidePlan,
  DayTaken: ({ day }) => `El ${day} ya tiene otra sesión.`,
  NotYours: notYours,
};

export const REQUIREMENT_REJECTIONS: Explanations<RejectionOf<PlanningResult, "FailedRecordDayRequirement">> = {
  PlanNotActive: planNotActive,
  DayOutsidePlan: dayOutsidePlan,
  NotYours: notYours,
};

export const RETIRE_REJECTIONS: Explanations<RejectionOf<PlanningResult, "FailedRetirePlan">> = {
  PlanNotActive: planNotActive,
  ImplausibleToday: () => "La fecha de este dispositivo no cuadra con la de Cadencia. Revisa la fecha y la hora.",
  NotYours: notYours,
};

export const ACCEPT_REJECTIONS: Explanations<RejectionOf<CoachResult, "FailedAcceptIntent">> = {
  NoOpenIntent: noOpenIntent,
  IntentExpired: () => "Esa propuesta era para días que ya han pasado.",
  NotYours: notYours,
};

export const DISMISS_REJECTIONS: Explanations<RejectionOf<CoachResult, "FailedDismissIntent">> = {
  NoOpenIntent: noOpenIntent,
  NotYours: notYours,
};

export const UNKNOWN_OUTCOME = "No sabemos si se guardó: Cadencia no respondió.";
const SIGNED_OUT = "Tu sesión ha terminado. Vuelve a conectar con Intervals.icu.";

const INTERVALS_PROBLEMS: Record<Exclude<IntervalsProblem, "signedOut">, string> = {
  notConnected: "Intervals.icu no está conectado.",
  unavailable: "No se pudo hablar con Intervals.icu. Vuelve a intentarlo.",
};

type Return = Update.Return<Model, Message, Clients>;

const clearMessages = { error: () => Option.none(), notice: () => Option.none() } as const;

/** Signed out: the session ended or was refused. Forget the athlete's data and offer to connect again. */
const signedOut = (model: Model): Return => ({
  model: modifyFields(model, {
    athleteId: () => null,
    plan: () => Option.none(),
    decision: () => Option.none(),
    thread: () => Option.none(),
    profile: () => Option.none(),
    history: () => AsyncData.Idle(),
    inFlight: () => Option.none(),
    savingDeclaration: () => false,
    confirmRetire: () => false,
    notice: () => Option.none(),
    error: () => Option.some(SIGNED_OUT),
  }),
});

/** Send a write, one at a time: while one is in flight, the others wait for its outcome. */
const send = (model: Model, write: Write): Return => {
  if (Option.isSome(model.inFlight)) return { model };
  const { commandId, commandIds } = DomainFoldkit.next(model.commandIds);
  return {
    model: modifyFields(model, {
      ...clearMessages,
      commandIds: () => commandIds,
      inFlight: () => Option.some({ write, commandId, outcome: "sending" as const }),
    }),
    commands: [commandFor(write, commandId)],
  };
};

/** Whether this result answers the write in flight; any other is stale and changes nothing. */
const answers = (model: Model, commandId: string) => Option.exists(model.inFlight, (f) => f.commandId === commandId);

const succeeded = (model: Model, commandId: string, notice: string, after: (model: Model) => Model = (m) => m): Return =>
  answers(model, commandId)
    ? { model: after(modifyFields(model, { inFlight: () => Option.none(), notice: () => Option.some(notice) })) }
    : { model };

type Failure<R> =
  | { readonly _tag: "Rejected"; readonly rejection: R }
  | { readonly _tag: "Denied" }
  | { readonly _tag: "Unknown" };

/** A refusal is final; a denial means signed out; an unknown outcome waits to be sent again with the same id. */
const failed = <R>(model: Model, commandId: string, failure: Failure<R>, text: (rejection: R) => string): Return => {
  if (!answers(model, commandId)) return { model };
  switch (failure._tag) {
    case "Rejected":
      return {
        model: modifyFields(model, { inFlight: () => Option.none(), error: () => Option.some(text(failure.rejection)) }),
      };
    case "Denied":
      return signedOut(model);
    case "Unknown":
      return {
        model: modifyFields(model, {
          inFlight: (f) => Option.map(f, (w) => ({ ...w, outcome: "unknown" as const })),
          error: () => Option.some(UNKNOWN_OUTCOME),
        }),
      };
  }
};

const planIdOf = (model: Model) =>
  Option.flatMap(model.plan, (plan) => (plan.status === "active" ? Option.fromNullishOr(plan.planId) : Option.none()));

const showsHistory = (section: Section) => section === "history" || section === "profile";

/** Move the history to `next` and read it for the current four weeks. */
const loadHistory = (model: Model, next: typeof History.schema.Type): Return => ({
  model: modifyFields(model, { history: () => next }),
  commands: [LoadIntervals({ range: historyOf(model.today) })],
});

/**
 * Read the history when a section shows it: loaded data stays on screen while
 * it refreshes, and a read already under way isn't started again.
 */
const revalidateHistory = (model: Model): Return =>
  model.athleteId === null || !showsHistory(model.section)
    ? { model }
    : Option.match(AsyncData.revalidateOrLoad(model.history), {
        onNone: () => ({ model }),
        onSome: (next) => loadHistory(model, next),
      });

/**
 * The four weeks moved: read them again now if they're on screen, or if a read
 * of the old ones is under way (its answer will be ignored, so nothing else
 * would end it). Otherwise the next visit reads them.
 */
const historyMoved = (model: Model): Return =>
  model.athleteId !== null && (showsHistory(model.section) || AsyncData.isPending(model.history))
    ? loadHistory(
        model,
        Option.match(AsyncData.getData(model.history), {
          onNone: () => AsyncData.Loading(),
          onSome: (data) => History.Refreshing({ data }),
        }),
      )
    : { model };

const sameRange = (a: HistoryRange, b: HistoryRange) => a.oldest === b.oldest && a.newest === b.newest;

/** A read worked: the reads are healthy again. */
const read = (model: Model): Return => ({ model: modifyFields(model, { readRetries: () => 0 }) });

/** The declaration wasn't saved: say why, and offer to connect again if Intervals isn't connected. */
const declarationFailed = (model: Model, problem: IntervalsProblem): Return =>
  problem === "signedOut"
    ? signedOut(model)
    : {
        model: modifyFields(model, {
          savingDeclaration: () => false,
          needsReconnect: () => problem === "notConnected",
          error: () => Option.some(INTERVALS_PROBLEMS[problem]),
        }),
      };

export const update = (model: Model, message: Message): Return =>
  Message.match<Return>(message, {
    ClickedSection: ({ section }) => revalidateHistory(modifyFields(model, { ...clearMessages, section: () => section })),
    ChangedDay: ({ today }) => (today === model.today ? { model } : historyMoved(modifyFields(model, { today: () => today }))),
    ReceivedPlan: ({ plan }) => read(modifyFields(model, { plan: () => plan })),
    ReceivedDecision: ({ decision }) => read(modifyFields(model, { decision: () => decision })),
    ReceivedThread: ({ thread }) => read(modifyFields(model, { thread: () => Option.some(thread) })),
    ReceivedProfile: ({ profile }) => read(modifyFields(model, { profile: () => profile })),
    RefusedRead: () => ({ model: modifyFields(model, { error: () => Option.some(notYours()) }) }),
    LostReads: () =>
      // The first failure takes the reads offline and schedules one reconnection; the others wait for it.
      model.readsOnline && model.athleteId !== null
        ? {
            model: modifyFields(model, { readsOnline: () => false, readRetries: (n) => n + 1 }),
            commands: [WaitToReconnect({ seconds: backoffSeconds(model.readRetries) })],
          }
        : { model },
    ReconnectedReads: () => ({ model: modifyFields(model, { readsOnline: () => true }) }),
    SignedOut: () => signedOut(model),
    SettledLoadIntervals: ({ range, result }) =>
      // An answer for four weeks that are no longer shown, or after signing out, is ignored.
      !sameRange(range, historyOf(model.today)) || !AsyncData.isPending(model.history)
        ? { model }
        : Result.isFailure(result) && result.failure === "signedOut"
          ? signedOut(model)
          : {
              model: modifyFields(model, {
                history: AsyncData.settle(result),
                ...(Result.isSuccess(result) ? { needsReconnect: () => false } : {}),
              }),
            },
    ClickedAcceptIntent: ({ conversationId, messageId }) =>
      send(model, Write.AcceptIntent({ target: conversationId, input: { messageId, today: model.today } })),
    ClickedDismissIntent: ({ conversationId, messageId }) =>
      send(model, Write.DismissIntent({ target: conversationId, input: { messageId } })),
    ChangedMove: ({ field, value }) => ({
      model: modifyFields(model, { move: (m) => ({ ...m, [field]: value }) }),
    }),
    SubmittedMove: () => {
      const planId = planIdOf(model);
      const toDay = Schema.decodeUnknownOption(Day)(model.move.toDay);
      const sessionId = Schema.decodeUnknownOption(SessionId)(model.move.sessionId);
      if (Option.isNone(planId) || Option.isNone(toDay) || Option.isNone(sessionId)) {
        return { model: modifyFields(model, { error: () => Option.some("Elige una sesión y un día nuevo.") }) };
      }
      return send(model, Write.MoveSession({ target: planId.value, input: { sessionId: sessionId.value, toDay: toDay.value } }));
    },
    ChangedRequirement: ({ field, value }) => ({
      model: modifyFields(model, { requirement: (r) => ({ ...r, [field]: value }) }),
    }),
    SubmittedRequirement: () => {
      const planId = planIdOf(model);
      const day = Schema.decodeUnknownOption(Day)(model.requirement.day);
      const instructions = Schema.decodeUnknownOption(Paragraph)(model.requirement.instructions.trim());
      const raw = model.requirement.maxMinutes.trim();
      const minutes = raw === "" ? Option.some(null) : Schema.decodeUnknownOption(Minutes)(Number(raw));
      if (Option.isNone(planId) || Option.isNone(day) || Option.isNone(instructions) || Option.isNone(minutes)) {
        return {
          model: modifyFields(model, { error: () => Option.some("Indica un día, una nota y, si quieres, un máximo de minutos.") }),
        };
      }
      return send(
        model,
        Write.RecordDayRequirement({
          target: planId.value,
          input: { day: day.value, instructions: instructions.value, maxMinutes: minutes.value },
        }),
      );
    },
    ClickedRetire: () => ({ model: modifyFields(model, { confirmRetire: () => true }) }),
    ClickedCancelRetire: () => ({ model: modifyFields(model, { confirmRetire: () => false }) }),
    ClickedConfirmRetire: () =>
      Option.match(planIdOf(model), {
        onNone: () => ({ model }),
        onSome: (planId) => {
          const next = send(model, Write.RetirePlan({ target: planId, input: { today: model.today } }));
          return { ...next, model: modifyFields(next.model, { confirmRetire: () => false }) };
        },
      }),
    ClickedRetryWrite: () =>
      Option.match(model.inFlight, {
        onNone: () => ({ model }),
        onSome: (inFlight): Return =>
          inFlight.outcome !== "unknown"
            ? { model }
            : {
                // The same command id: the write may have been applied, and the domain applies it once.
                model: modifyFields(model, {
                  ...clearMessages,
                  inFlight: () => Option.some({ ...inFlight, outcome: "sending" as const }),
                }),
                commands: [commandFor(inFlight.write, inFlight.commandId)],
              },
      }),
    ClickedForgetWrite: () =>
      Option.exists(model.inFlight, (f) => f.outcome === "unknown")
        ? { model: modifyFields(model, { ...clearMessages, inFlight: () => Option.none() }) }
        : { model },
    ReceivedPlanningResult: ({ result }) =>
      PlanningClient.Message.match<Return>(result, {
        SucceededMoveSession: ({ commandId }) =>
          succeeded(model, commandId, "Sesión movida.", (m) => modifyFields(m, { move: () => ({ sessionId: "", toDay: "" }) })),
        FailedMoveSession: ({ commandId, failure }) => failed(model, commandId, failure, explain(MOVE_REJECTIONS)),
        SucceededRecordDayRequirement: ({ commandId }) =>
          succeeded(model, commandId, "Guardado. El plan ya lo tiene en cuenta.", (m) =>
            modifyFields(m, { requirement: () => ({ day: model.today, maxMinutes: "", instructions: "" }) }),
          ),
        FailedRecordDayRequirement: ({ commandId, failure }) =>
          failed(model, commandId, failure, explain(REQUIREMENT_REJECTIONS)),
        SucceededRetirePlan: ({ commandId }) => succeeded(model, commandId, "Plan retirado."),
        FailedRetirePlan: ({ commandId, failure }) => failed(model, commandId, failure, explain(RETIRE_REJECTIONS)),
      }),
    ReceivedCoachResult: ({ result }) =>
      CoachClient.Message.match<Return>(result, {
        SucceededAcceptIntent: ({ commandId }) =>
          succeeded(model, commandId, "Propuesta aceptada. El plan la aplicará si cumple sus reglas."),
        FailedAcceptIntent: ({ commandId, failure }) => failed(model, commandId, failure, explain(ACCEPT_REJECTIONS)),
        SucceededDismissIntent: ({ commandId }) => succeeded(model, commandId, "Propuesta descartada."),
        FailedDismissIntent: ({ commandId, failure }) => failed(model, commandId, failure, explain(DISMISS_REJECTIONS)),
        // The web never sends it: the FTP proposal is answered in iOS.
        SucceededDismissFtpProposal: () => ({ model }),
        FailedDismissFtpProposal: () => ({ model }),
      }),
    ChangedDeclaration: ({ field, value }) => ({
      model: modifyFields(model, { declaration: (d) => ({ ...d, [field]: value }) }),
    }),
    SubmittedDeclaration: () =>
      model.savingDeclaration
        ? { model }
        : Option.match(declarationOf(model.declaration), {
            onNone: () => ({
              model: modifyFields(model, {
                error: () => Option.some("Revisa los datos: las escalas van de 1 a 4 y el peso, de 20 a 350 kg."),
              }),
            }),
            onSome: (declaration) => ({
              model: modifyFields(model, { ...clearMessages, savingDeclaration: () => true }),
              commands: [SaveDeclaration({ day: model.today, declaration })],
            }),
          }),
    SavedDeclaration: () => {
      const saved = modifyFields(model, {
        savingDeclaration: () => false,
        declaration: () => emptyDeclaration,
        notice: () => Option.some("Guardado en Intervals.icu."),
      });
      // Today's wellness changed: refresh the history if it holds data.
      return Option.match(AsyncData.revalidate(saved.history), {
        onNone: () => ({ model: saved }),
        onSome: (next) => loadHistory(saved, next),
      });
    },
    FailedDeclaration: ({ problem }) => declarationFailed(model, problem),
  });

// INIT

export const init = (flags: Flags): Return => ({
  model: Model.make({
    athleteId: flags.athleteId,
    today: flags.today,
    section: "home",
    commandIds: { session: flags.session, sent: 0 },
    readsOnline: true,
    readRetries: 0,
    plan: Option.none(),
    decision: Option.none(),
    thread: Option.none(),
    profile: Option.none(),
    history: AsyncData.Idle(),
    move: { sessionId: "", toDay: "" },
    requirement: { day: flags.today, maxMinutes: "", instructions: "" },
    declaration: emptyDeclaration,
    savingDeclaration: false,
    confirmRetire: false,
    inFlight: Option.none(),
    needsReconnect: false,
    notice: Option.none(),
    error: Option.none(),
  }),
});

// SUBSCRIPTION

/**
 * Keys must be well-formed even before anyone signs in. This athlete id is
 * never read: every watch is disabled while signed out.
 */
const NOBODY = AthleteId.make("i1");

const ownerOf = (model: Model): AthleteId => model.athleteId ?? NOBODY;
export const conversationOf = (model: Model): ConversationId => conversationIdFor(ownerOf(model), monthOf(model.today));

/** Live reads run while signed in, unless they are waiting out a transport failure. */
const reading = (model: Model) => model.athleteId !== null && model.readsOnline;

type ReadFailure = NotYours | Unauthorized | RpcClientError.RpcClientError;

/** A read ended: refused, signed out, or the connection dropped. */
export const readFailed = (error: ReadFailure): Message => {
  switch (error._tag) {
    case "Unauthorized":
      return Message.SignedOut();
    case "NotYours":
      return Message.RefusedRead();
    case "RpcClientError":
      return Message.LostReads();
  }
};

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
    onFailure: readFailed,
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
    onFailure: readFailed,
    onDefect: lostReads,
  }),
  decision: CoachClient.TodayDecision.watch({
    key: (model: Model) => dailyDecisionIdFor(ownerOf(model), model.today),
    isEnabled: reading,
    toMessage: ({ state }): Message => Message.ReceivedDecision({ decision: state }),
    onFailure: readFailed,
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
    onFailure: readFailed,
    onDefect: lostReads,
  }),
}));

// VIEW

const SECTIONS: ReadonlyArray<readonly [Section, string]> = [
  ["home", "Hoy"],
  ["coach", "Coach"],
  ["plan", "Plan"],
  ["history", "Historial"],
  ["profile", "Perfil"],
];

const KIND: Record<SessionKind, string> = {
  rest: "Descanso",
  recovery: "Recuperación",
  endurance: "Resistencia",
  tempo: "Sweet spot",
  threshold: "Umbral",
  vo2max: "VO₂max",
  openerActivation: "Activación",
  longRide: "Tirada larga",
  groupRide: "Grupeta",
  race: "Carrera",
  strength: "Fuerza",
};

const STATUS: Record<SessionStatus, readonly [string, string]> = {
  provisional: ["Provisional", "info"],
  concrete: ["Concretada", "info"],
  published: ["En Intervals", "good"],
  skipped: ["Omitida", "warn"],
  changedInIntervals: ["Cambiada en Intervals", "warn"],
  removedInIntervals: ["Borrada en Intervals", "bad"],
};

/** Sessions Cadencia still owns and that still ride: the only ones the plan lets the athlete move. */
export const isMovable = (session: PlannedSession) =>
  session.status === "provisional" || session.status === "concrete" || session.status === "published";

const CALENDAR_PROBLEMS: Record<CalendarProblem, string> = {
  notConnected: "Intervals.icu no está conectado",
  refused: "Intervals.icu rechazó esta sesión",
};

const REFUSALS: Record<RefusalReason, string> = {
  planNotActive: "el plan no está activo",
  dayNotPlanned: "ese día no tiene sesión",
  availabilityExceeded: "supera el tiempo disponible",
  intensityAfterHardTraining: "hay entrenamiento duro el mismo día o el anterior",
  hardensPlan: "endurecía una sesión suave del plan",
  purposeMismatch: "no encaja con el propósito de la sesión",
  invalidPlan: "el borrador no es un plan válido",
  planAlreadyExists: "el plan ya existe",
  implausibleToday: "la fecha del dispositivo no cuadraba",
  notYours: "no tienes permiso",
};

const refusalText = (refusal: { readonly reason: RefusalReason } | null) => (refusal === null ? "" : REFUSALS[refusal.reason]);

const minutesOf = (workout: Workout) => Math.round(totalMinutes(workout));

const workoutLine = (workout: Workout) => `${workout.name} · ${KIND[workout.kind]} · ${minutesOf(workout)} min`;

const pill = (h: HtmlBuilder<Message>, text: string, tone: string) => h.span([h.Class(`pill ${tone}`)], [text]);

const reconnectLink = (h: HtmlBuilder<Message>, text: string) => h.a([h.Href("/auth/intervals/start")], [text]);

/** Whether a write is waiting: every write control is disabled until it settles. */
const busy = (model: Model) => Option.isSome(model.inFlight);

const homeView = (model: Model, h: HtmlBuilder<Message>) => {
  const decision = Option.getOrNull(model.decision);
  const upcoming = Option.match(model.plan, {
    onNone: () => [],
    onSome: (plan) => plan.sessions.filter((s) => s.day >= model.today && s.day <= addDays(model.today, 6)),
  });
  const problems = Option.match(model.plan, { onNone: () => [], onSome: (plan) => plan.calendarProblems });
  const decisionCard =
    decision === null || decision.status === "none" || decision.note === null
      ? h.div([h.Class("card")], [
          h.h2([], ["Hoy"]),
          h.p([h.Class("muted")], ["La decisión de hoy aparecerá cuando abras Cadencia en el iPhone."]),
        ])
      : h.div([h.Class("card")], [
          h.h2([], [decision.note.headline]),
          decision.status === "accepted"
            ? pill(h, "Aceptada por el plan", "good")
            : decision.status === "refused"
              ? pill(h, `El plan la rechazó: ${refusalText(decision.refusal)}`, "bad")
              : pill(h, "Esperando al plan", "info"),
          h.p([], [decision.note.body]),
          h.p([], [decision.note.session]),
          ...(decision.note.watch ? [h.p([h.Class("muted")], [decision.note.watch])] : []),
          ...(decision.workout ? [h.p([h.Class("muted")], [workoutLine(decision.workout)])] : []),
          // The plan keeps the last proposal it accepted, which can be an earlier attempt.
          ...(decision.planHolds !== null && decision.planHolds.attempt !== decision.attempt
            ? [h.p([], [`El plan mantiene: ${decision.planHolds.note.headline} (${workoutLine(decision.planHolds.workout)})`])]
            : []),
          ...(decision.awaiting.length > 0 && decision.status !== "pending"
            ? [h.p([h.Class("muted")], ["Hay otra propuesta esperando la respuesta del plan."])]
            : []),
          ...(decision.evidence
            ? [h.p([h.Class("muted")], [`Readiness: ${decision.evidence.readiness.summary} (${decision.evidence.readiness.score}/100)`])]
            : []),
          h.p([h.Class("muted")], [`Interpretado en iOS con ${decision.model ?? "?"}.`]),
        ]);
  return [
    decisionCard,
    h.div([h.Class("card")], [
      h.h2([], ["Próximos 7 días"]),
      upcoming.length === 0
        ? h.p([h.Class("muted")], ["No hay sesiones planificadas esta semana."])
        : sessionsTable(h, upcoming, problems),
    ]),
  ];
};

const sessionsTable = (
  h: HtmlBuilder<Message>,
  sessions: ReadonlyArray<PlannedSession>,
  problems: (typeof CurrentPlanState.Type)["calendarProblems"],
) =>
  h.div([h.Class("scroll")], [
    h.table([], [
      h.thead([], [h.tr([], [h.th([], ["Día"]), h.th([], ["Sesión"]), h.th([], ["Min"]), h.th([], ["Estado"])])]),
      h.tbody(
        [],
        sessions.map((s) => {
          const [label, tone] = STATUS[s.status];
          const problem = problems.find((p) => p.sessionId === s.sessionId);
          return h.keyed("tr")(s.sessionId, [], [
            h.td([], [s.day]),
            h.td([], [`${s.workout?.name ?? s.title} · ${KIND[s.kind]}`]),
            h.td([], [String(s.workout ? minutesOf(s.workout) : s.targetMinutes)]),
            h.td([], [
              pill(h, label, tone),
              ...(problem === undefined
                ? []
                : [
                    h.p([h.Class("error")], [
                      CALENDAR_PROBLEMS[problem.problem],
                      ...(problem.problem === "notConnected" ? [" · ", reconnectLink(h, "Conectar de nuevo")] : []),
                    ]),
                  ]),
            ]),
          ]);
        }),
      ),
    ]),
  ]);

const coachView = (model: Model, h: HtmlBuilder<Message>) => {
  const thread = Option.getOrNull(model.thread);
  const messages = thread?.messages ?? [];
  return [
    h.div([h.Class("card")], [
      h.h2([], ["Conversación de este mes"]),
      h.p([h.Class("muted")], [
        "Para escribir al coach usa Cadencia en el iPhone: la respuesta necesita la IA. Aquí puedes aceptar o descartar lo que te propone.",
      ]),
      ...(thread === null || messages.length === 0
        ? [h.p([h.Class("muted")], ["Todavía no hay mensajes este mes."])]
        : messages.map((m) =>
            h.keyed("div")(m.messageId, [h.Class(`message ${m.role}`)], [
              h.p([], [m.text]),
              ...(m.intent
                ? [
                    h.p([h.Class("muted")], [`Propuesta: ${m.intent.summary}`]),
                    m.intentStatus === "proposed"
                      ? h.div([h.Class("row")], [
                          h.button(
                            [
                              h.Class("primary"),
                              h.Disabled(busy(model)),
                              h.OnClick(Message.ClickedAcceptIntent({ conversationId: thread.conversationId, messageId: m.messageId })),
                            ],
                            ["Aceptar"],
                          ),
                          h.button(
                            [
                              h.Class("secondary"),
                              h.Disabled(busy(model)),
                              h.OnClick(Message.ClickedDismissIntent({ conversationId: thread.conversationId, messageId: m.messageId })),
                            ],
                            ["Descartar"],
                          ),
                        ])
                      : pill(
                          h,
                          m.intentStatus === "applied"
                            ? "Aplicada al plan"
                            : m.intentStatus === "refused"
                              ? `El plan la rechazó: ${refusalText(m.refusal)}`
                              : m.intentStatus === "dismissed"
                                ? "Descartada"
                                : "Aceptada",
                          m.intentStatus === "applied" ? "good" : m.intentStatus === "refused" ? "bad" : "info",
                        ),
                  ]
                : []),
            ]),
          )),
    ]),
  ];
};

const planView = (model: Model, h: HtmlBuilder<Message>) =>
  Option.match(model.plan, {
    onNone: () => [
      h.div([h.Class("card")], [
        h.h2([], ["Sin plan"]),
        h.p([h.Class("muted")], ["Los planes se crean con la consulta del coach en Cadencia para iPhone."]),
      ]),
    ],
    onSome: (plan) => [
      h.div([h.Class("card")], [
        h.h2([], [plan.title ?? "Plan"]),
        pill(h, plan.status === "active" ? "Activo" : "Retirado", plan.status === "active" ? "good" : "warn"),
        ...(plan.objective === null ? [] : [h.p([], [plan.objective])]),
        h.p([h.Class("muted")], [`${plan.startDay ?? ""} → ${plan.endDay ?? ""}`]),
        h.ul([], plan.phases.map((p) => h.li([], [`Semanas ${p.startWeek}–${p.endWeek}: ${p.summary}`]))),
      ]),
      h.div([h.Class("card")], [h.h2([], ["Sesiones"]), sessionsTable(h, plan.sessions, plan.calendarProblems)]),
      ...(plan.status === "active"
        ? [
            h.div([h.Class("card")], [
              h.h2([], ["Mover una sesión"]),
              h.p([h.Class("muted")], ["Las sesiones que cambiaste en Intervals.icu se mueven allí."]),
              h.form([h.Class("row"), h.OnSubmit(Message.SubmittedMove())], [
                h.label([], [
                  "Sesión",
                  h.select(
                    [h.Value(model.move.sessionId), h.OnChange((value) => Message.ChangedMove({ field: "sessionId", value }))],
                    [
                      h.option([h.Value("")], ["Elige…"]),
                      ...plan.sessions
                        .filter((s) => s.day >= model.today && isMovable(s))
                        .map((s) => h.option([h.Value(s.sessionId)], [`${s.day} · ${s.title}`])),
                    ],
                  ),
                ]),
                h.label([], [
                  "Nuevo día",
                  h.input([h.Type("date"), h.Value(model.move.toDay), h.OnInput((value) => Message.ChangedMove({ field: "toDay", value }))]),
                ]),
                h.button([h.Class("primary"), h.Type("submit"), h.Disabled(busy(model))], ["Mover"]),
              ]),
            ]),
            h.div([h.Class("card")], [
              h.h2([], ["Requisito para un día"]),
              h.p([h.Class("muted")], ["El plan nunca te propondrá más minutos de los que indiques, y ajusta la sesión de ese día al momento."]),
              h.form([h.Class("row"), h.OnSubmit(Message.SubmittedRequirement())], [
                h.label([], [
                  "Día",
                  h.input([
                    h.Type("date"),
                    h.Value(model.requirement.day),
                    h.OnInput((value) => Message.ChangedRequirement({ field: "day", value })),
                  ]),
                ]),
                h.label([], [
                  "Máximo de minutos",
                  h.input([
                    h.Type("number"),
                    h.Min("0"),
                    h.Value(model.requirement.maxMinutes),
                    h.OnInput((value) => Message.ChangedRequirement({ field: "maxMinutes", value })),
                  ]),
                ]),
                h.label([], [
                  "Nota",
                  h.input([
                    h.Type("text"),
                    h.Value(model.requirement.instructions),
                    h.OnInput((value) => Message.ChangedRequirement({ field: "instructions", value })),
                  ]),
                ]),
                h.button([h.Class("primary"), h.Type("submit"), h.Disabled(busy(model))], ["Guardar"]),
              ]),
            ]),
            h.div([h.Class("card")], [
              h.h2([], ["Retirar el plan"]),
              h.p([h.Class("muted")], ["Sus sesiones desde hoy salen del calendario de Intervals.icu."]),
              model.confirmRetire
                ? h.div([h.Class("row")], [
                    h.button(
                      [h.Class("primary"), h.Disabled(busy(model)), h.OnClick(Message.ClickedConfirmRetire())],
                      ["Sí, retirar el plan"],
                    ),
                    h.button([h.Class("secondary"), h.OnClick(Message.ClickedCancelRetire())], ["Cancelar"]),
                  ])
                : h.button([h.Class("secondary"), h.Disabled(busy(model)), h.OnClick(Message.ClickedRetire())], ["Retirar el plan"]),
            ]),
          ]
        : []),
    ],
  });

const intervalsProblemText = (problem: IntervalsProblem) =>
  problem === "signedOut" ? SIGNED_OUT : INTERVALS_PROBLEMS[problem];

/** Why the history couldn't be read, with a way to connect again when that's the reason. */
const historyProblem = (h: HtmlBuilder<Message>, problem: IntervalsProblem) =>
  h.p([h.Class("error"), h.AriaLive("polite")], [
    intervalsProblemText(problem),
    ...(problem === "notConnected" ? [" ", reconnectLink(h, "Conectar de nuevo")] : []),
  ]);

/**
 * The cards built from the history, in every state it can be in: until it is
 * read, or when it can't be, one card titled `title` says so. Data already on
 * screen stays there while it refreshes, and when a refresh fails.
 */
const historyCards = (
  model: Model,
  h: HtmlBuilder<Message>,
  title: string,
  cards: (history: IntervalsHistory) => ReadonlyArray<Html>,
): ReadonlyArray<Html> => {
  const alone = (content: Html) => [h.div([h.Class("card")], [h.h2([], [title]), content])];
  const loading = () => alone(h.p([h.Class("muted"), h.AriaLive("polite")], ["Leyendo Intervals.icu…"]));
  return AsyncData.match(model.history, {
    onIdle: loading,
    onLoading: loading,
    onFailure: (problem) => alone(historyProblem(h, problem)),
    onRefreshing: (history) => [h.p([h.Class("muted"), h.AriaLive("polite")], ["Actualizando desde Intervals.icu…"]), ...cards(history)],
    onStale: ({ error, data }) => [historyProblem(h, error), ...cards(data)],
    onSuccess: cards,
  });
};

const historyView = (model: Model, h: HtmlBuilder<Message>) =>
  historyCards(model, h, "Forma", ({ wellness, activities }) => {
  const latest = wellness.at(-1);
  return [
    h.div([h.Class("card")], [
      h.h2([], ["Forma"]),
      latest && latest.fitness !== null && latest.acuteLoad !== null
        ? h.p([], [
            `Forma (CTL) ${latest.fitness.toFixed(0)} · Fatiga (ATL) ${latest.acuteLoad.toFixed(0)} · Balance ${(latest.fitness - latest.acuteLoad).toFixed(0)}`,
          ])
        : h.p([h.Class("muted")], ["Sin datos de bienestar en las últimas cuatro semanas."]),
    ]),
    h.div([h.Class("card")], [
      h.h2([], ["Actividades de las últimas cuatro semanas"]),
      activities.length === 0
        ? h.p([h.Class("muted")], ["No hay actividades en Intervals.icu en estas fechas."])
        : h.div([h.Class("scroll")], [
            h.table([], [
              h.thead([], [
                h.tr([], [h.th([], ["Fecha"]), h.th([], ["Actividad"]), h.th([], ["Min"]), h.th([], ["Carga"]), h.th([], ["NP"])]),
              ]),
              h.tbody(
                [],
                [...activities].reverse().map((a) =>
                  h.keyed("tr")(a.activityId, [], [
                    h.td([], [a.day ?? ""]),
                    h.td([], [a.name ?? ""]),
                    h.td([], [a.movingTime !== null ? String(Math.round(a.movingTime / 60)) : ""]),
                    h.td([], [a.trainingLoad !== null ? a.trainingLoad.toFixed(0) : ""]),
                    h.td([], [a.normalizedPower !== null ? `${a.normalizedPower.toFixed(0)} W` : ""]),
                  ]),
                ),
              ),
            ]),
          ]),
    ]),
  ];
  });

const scale = (h: HtmlBuilder<Message>, label: string, field: "mood" | "motivation" | "soreness" | "fatigue", value: string) =>
  h.label([], [
    label,
    h.select(
      [h.Value(value), h.OnChange((v) => Message.ChangedDeclaration({ field, value: v }))],
      [h.option([h.Value("")], ["—"]), ...["1", "2", "3", "4"].map((n) => h.option([h.Value(n)], [n]))],
    ),
  ]);

const profileView = (model: Model, h: HtmlBuilder<Message>) => {
  const report = Option.getOrNull(Option.flatMap(model.profile, (p) => Option.fromNullishOr(p.report)));
  return [
    ...historyCards(model, h, "Tu perfil", ({ athlete }) => [
      h.div([h.Class("card")], [
        h.h2([], [athlete.name ?? "Tu perfil"]),
        h.p([], [`Peso: ${athlete.weight != null ? `${athlete.weight} kg` : "—"} · FTP: ${athlete.ftp != null ? `${athlete.ftp} W` : "—"}`]),
        h.p([h.Class("muted")], ["Estos datos viven en Intervals.icu."]),
      ]),
    ]),
    h.div([h.Class("card")], [
      h.h2([], ["Cómo estás hoy"]),
      h.p([h.Class("muted")], ["Se guarda en el bienestar de hoy en Intervals.icu (escala de Intervals, 1 a 4)."]),
      h.form([h.Class("row"), h.OnSubmit(Message.SubmittedDeclaration())], [
        scale(h, "Ánimo", "mood", model.declaration.mood),
        scale(h, "Motivación", "motivation", model.declaration.motivation),
        scale(h, "Agujetas", "soreness", model.declaration.soreness),
        scale(h, "Fatiga", "fatigue", model.declaration.fatigue),
        h.label([], [
          "Peso (kg)",
          h.input([
            h.Type("number"),
            h.Value(model.declaration.weight),
            h.OnInput((value) => Message.ChangedDeclaration({ field: "weight", value })),
          ]),
        ]),
        h.label([], [
          "Comentario",
          h.input([
            h.Type("text"),
            h.Value(model.declaration.comments),
            h.OnInput((value) => Message.ChangedDeclaration({ field: "comments", value })),
          ]),
        ]),
        h.button([h.Class("primary"), h.Type("submit"), h.Disabled(model.savingDeclaration)], ["Guardar en Intervals"]),
      ]),
    ]),
    h.div([h.Class("card")], [
      h.h2([], ["Perfil de ciclista"]),
      report === null
        ? h.p([h.Class("muted")], ["Se genera con la IA desde Cadencia para iPhone."])
        : h.div([], [
            h.p([], [h.strong([], [report.headline])]),
            h.p([], [report.summary]),
            h.p([h.Class("muted")], [
              `Basado en ${report.rideCount} salidas, ${report.oldest} → ${report.newest}. Confianza: ${report.confidence}.`,
            ]),
          ]),
    ]),
  ];
};

/** The write in flight, or the one whose outcome is unknown, with what can be done about it. */
const writeStatus = (model: Model, h: HtmlBuilder<Message>) =>
  Option.match(model.inFlight, {
    onNone: () => [],
    onSome: (inFlight) =>
      inFlight.outcome === "sending"
        ? [h.p([h.Class("muted"), h.AriaLive("polite")], ["Guardando…"])]
        : [
            h.div([h.Class("row"), h.AriaLive("polite")], [
              h.button([h.Class("primary"), h.OnClick(Message.ClickedRetryWrite())], ["Reintentar"]),
              h.button([h.Class("secondary"), h.OnClick(Message.ClickedForgetWrite())], ["Dejarlo"]),
            ]),
          ],
  });

export const view = (model: Model, h: HtmlBuilder<Message>): Document => ({
  title: "Cadencia",
  body: h.div([h.Class("app")], [
    h.header([h.Class("top")], [
      h.h1([], ["Cadencia"]),
      ...(model.athleteId === null
        ? []
        : [
            h.nav(
              [h.Class("sections"), h.AriaLabel("Secciones")],
              SECTIONS.map(([section, label]) =>
                h.button(
                  [h.OnClick(Message.ClickedSection({ section })), ...(model.section === section ? [h.AriaCurrent("page")] : [])],
                  [label],
                ),
              ),
            ),
          ]),
    ]),
    ...(model.athleteId === null
      ? [
          h.div([h.Class("card")], [
            h.h2([], ["Entra con tu cuenta de Intervals.icu"]),
            ...Option.match(model.error, { onNone: () => [], onSome: (e) => [h.p([h.Class("error")], [e])] }),
            h.p([], ["Cadencia usa Intervals.icu como fuente de verdad: tus actividades, tu bienestar y tu calendario siguen allí."]),
            h.a([h.Class("connect"), h.Href("/auth/intervals/start")], ["Conectar con Intervals.icu"]),
          ]),
        ]
      : [
          ...(model.readsOnline ? [] : [h.p([h.Class("muted"), h.AriaLive("polite")], ["Sin conexión con Cadencia. Reintentando…"])]),
          ...Option.match(model.error, {
            onNone: () => [],
            onSome: (e) => [
              h.p([h.Class("error"), h.AriaLive("polite")], [
                e,
                ...(model.needsReconnect ? [" ", reconnectLink(h, "Conectar de nuevo")] : []),
              ]),
            ],
          }),
          ...writeStatus(model, h),
          ...Option.match(model.notice, { onNone: () => [], onSome: (n) => [h.p([h.Class("muted"), h.AriaLive("polite")], [n])] }),
          ...(model.section === "home"
            ? homeView(model, h)
            : model.section === "coach"
              ? coachView(model, h)
              : model.section === "plan"
                ? planView(model, h)
                : model.section === "history"
                  ? historyView(model, h)
                  : profileView(model, h)),
        ]),
  ]),
});
