import { ActivitySummary } from "@cadencia/athlete/ActivitySummary";
import { AthleteMeasures } from "@cadencia/athlete/AthleteMeasures";
import { HistoryRange } from "@cadencia/athlete/HistoryRange";
import { Kilograms, WellnessScale } from "@cadencia/athlete/Measures";
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
import * as Function from "effect/Function";
import * as Array from "effect/Array";
import * as Data from "effect/Data";
import * as HttpClient from "effect/http/HttpClient";
import * as HttpClientRequest from "effect/http/HttpClientRequest";
import * as HttpClientResponse from "effect/http/HttpClientResponse";
import * as Match from "effect/Match";
import * as Option from "effect/Option";
import * as Record from "effect/Record";
import * as Result from "effect/Result";
import type * as RpcClientError from "effect/rpc/RpcClientError";
import * as Schema from "effect/Schema";
import * as Stream from "effect/Stream";
import { AsyncData, Command, FieldValidation, Http, Navigation, Subscription, Update, Url } from "foldkit";
import { Rule } from "foldkit/fieldValidation";
import type { Attribute, Document, Html, HtmlBuilder } from "foldkit/html";
import { defineMessageUnion } from "foldkit/message";
import { defineTaggedUnion } from "foldkit/schema";
import { modifyFields } from "foldkit/struct";
import { AppRoute, coachRouter, historyRouter, homeRouter, planRouter, profileRouter, routeOf } from "./Route.ts";

type Clients = Domain.Api.ClientKey<"AthletePlanningApi"> | Domain.Api.ClientKey<"AthleteCoachApi">;
export const PlanningClient = DomainFoldkit.make(AthletePlanningApi);
export const CoachClient = DomainFoldkit.make(AthleteCoachApi);

// MODEL


/** The views' own state schemas: the app keeps exactly what the domain shows. */
const DecisionState = TodayDecision.State;
const ProfileState = RiderProfileCard.State;

/** A month of conversation, with the id it was read under: an intent's answer goes back to it. */
const Thread = Schema.Struct({ conversationId: ConversationId, messages: Schema.Array(ThreadMessage) });

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
type HistoryData = typeof History.schema.Type;

// FORMS

/**
 * The domain values the forms ask for, decoded from the text their controls
 * hold with the domain's own schemas: a field passes its rule exactly when the
 * command will accept it.
 */
const MinutesText = Schema.FiniteFromString.pipe(Schema.decodeTo(Minutes));
const ParagraphText = Schema.Trim.pipe(Schema.decodeTo(Paragraph));
const ScaleText = Schema.FiniteFromString.pipe(Schema.decodeTo(WellnessScale));
const KilogramsText = Schema.FiniteFromString.pipe(Schema.decodeTo(Kilograms));

const isBlank = (text: string) => text.trim() === "";

/** A field's text: what its control holds, and whether it passes its rules. */
const TextField = FieldValidation.Field(Schema.String);
type TextField = typeof TextField.Type;
const blank = (value = ""): TextField => FieldValidation.NotValidated({ value });

export const MOVE_RULES = {
  sessionId: FieldValidation.makeRules({ required: "Elige una sesión.", rules: [Rule.fromSchema(SessionId, "Esa sesión no es válida.")] }),
  toDay: FieldValidation.makeRules({ required: "Elige el día nuevo.", rules: [Rule.fromSchema(Day, "Ese día no es válido.")] }),
};

export const REQUIREMENT_RULES = {
  day: FieldValidation.makeRules({ required: "Elige el día.", rules: [Rule.fromSchema(Day, "Ese día no es válido.")] }),
  maxMinutes: FieldValidation.makeRules({
    isEmpty: isBlank,
    rules: [Rule.fromSchema(MinutesText, "Un número entero de minutos, de 0 a 1440.")],
  }),
  instructions: FieldValidation.makeRules({
    required: "Escribe qué necesitas ese día.",
    isEmpty: isBlank,
    rules: [Rule.fromSchema(ParagraphText, "La nota es demasiado larga (4000 caracteres como máximo).")],
  }),
};

const scaleRules = FieldValidation.makeRules({ rules: [Rule.fromSchema(ScaleText, "De 1 a 4.")] });

export const DECLARATION_RULES = {
  mood: scaleRules,
  motivation: scaleRules,
  soreness: scaleRules,
  fatigue: scaleRules,
  weight: FieldValidation.makeRules({ isEmpty: isBlank, rules: [Rule.fromSchema(KilogramsText, "Entre 20 y 350 kg.")] }),
  comments: FieldValidation.makeRules({
    isEmpty: isBlank,
    rules: [Rule.fromSchema(ParagraphText, "El comentario es demasiado largo (4000 caracteres como máximo).")],
  }),
};

/** A form's fields by name, and the rules each must pass. */
type Form<Name extends string> = { readonly [N in Name]: TextField };
type FormRules<Name extends string> = { readonly [N in Name]: FieldValidation.Rules<string> };

const MoveForm = Schema.Struct({ sessionId: TextField, toDay: TextField });
const RequirementForm = Schema.Struct({ day: TextField, maxMinutes: TextField, instructions: TextField });
const DeclarationForm = Schema.Struct({
  mood: TextField,
  motivation: TextField,
  soreness: TextField,
  fatigue: TextField,
  weight: TextField,
  comments: TextField,
});
type DeclarationForm = typeof DeclarationForm.Type;

const emptyMove: Form<keyof typeof MOVE_RULES> = { sessionId: blank(), toDay: blank() };
const emptyRequirement = (day: Day): Form<keyof typeof REQUIREMENT_RULES> => ({
  day: blank(day),
  maxMinutes: blank(),
  instructions: blank(),
});
const emptyDeclaration: DeclarationForm = {
  mood: blank(),
  motivation: blank(),
  soreness: blank(),
  fatigue: blank(),
  weight: blank(),
  comments: blank(),
};

/** One field edited: checked against its rules as the athlete types. */
const edit = <Name extends string>(form: Form<Name>, rules: FormRules<Name>, name: Name, value: string): Form<Name> => ({
  ...form,
  [name]: FieldValidation.validate(rules[name])(value),
});

/** Every field checked, as on submit: a required field left untouched shows its message too. */
const check = <Name extends string>(form: Form<Name>, rules: FormRules<Name>): Form<Name> =>
  Record.map(rules, (fieldRules, name) => FieldValidation.validate(fieldRules)(form[name].value));

const decode =
  <A>(schema: Schema.Codec<A, string>) =>
  (field: TextField): Option.Option<A> =>
    Schema.decodeUnknownOption(schema)(field.value);

/** An optional field: blank is `null`; anything else must decode. */
const decodeOptional =
  <A>(schema: Schema.Codec<A, string>) =>
  (field: TextField): Option.Option<A | null> =>
    isBlank(field.value) ? Option.some(null) : decode(schema)(field);

/** What the move form sends, once every field holds what the command accepts. */
export const moveOf = (form: Form<keyof typeof MOVE_RULES>) =>
  Option.all({ sessionId: decode(SessionId)(form.sessionId), toDay: decode(Day)(form.toDay) });

/** What the day's requirement sends, once every field holds what the command accepts. */
export const requirementOf = (form: Form<keyof typeof REQUIREMENT_RULES>) =>
  Option.all({
    day: decode(Day)(form.day),
    instructions: decode(ParagraphText)(form.instructions),
    maxMinutes: decodeOptional(MinutesText)(form.maxMinutes),
  });

/** What the wellness form saves: the fields filled in, each as Intervals takes it. */
export const declarationOf = (form: DeclarationForm): Option.Option<WellnessDeclaration> =>
  Option.all({
    mood: decodeOptional(ScaleText)(form.mood),
    motivation: decodeOptional(ScaleText)(form.motivation),
    soreness: decodeOptional(ScaleText)(form.soreness),
    fatigue: decodeOptional(ScaleText)(form.fatigue),
    weight: decodeOptional(KilogramsText)(form.weight),
    comments: decodeOptional(ParagraphText)(form.comments),
  }).pipe(
    Option.map(Record.filter((value) => value !== null)),
    Option.flatMap(Schema.decodeUnknownOption(WellnessDeclaration)),
  );

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

/** Moves to another of the web's pages without reloading it. */
export const NavigateInternal = Command.define("NavigateInternal", {
  args: { url: Schema.String },
  messages: [Message.CompletedNavigateInternal],
  execute: ({ url }) => Navigation.pushUrl(url).pipe(Effect.as(Message.CompletedNavigateInternal())),
});

/** Loads a page the server serves, such as signing in with Intervals.icu or the privacy policy. */
export const LoadPage = Command.define("LoadPage", {
  args: { href: Schema.String },
  messages: [Message.CompletedLoadPage],
  execute: ({ href }) => Navigation.load(href).pipe(Effect.as(Message.CompletedLoadPage())),
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
    plan: () => AsyncData.Idle(),
    decision: () => AsyncData.Idle(),
    thread: () => AsyncData.Idle(),
    profile: () => AsyncData.Idle(),
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
  AsyncData.getData(model.plan).pipe(
    Option.flatten,
    Option.filter((plan) => plan.status === "active"),
    Option.flatMap((plan) => Option.fromNullishOr(plan.planId)),
  );

const showsHistory = AppRoute.isAnyOf(["History", "Profile"]);

const isSignedIn = (model: Model) => model.athleteId !== null;

/** A signed-in athlete is on a page that shows the history. */
const historyOnScreen = (model: Model) => isSignedIn(model) && showsHistory(model.route);

/** Read again whatever the state: data on screen stays there while it reloads. */
const reload = (history: HistoryData): Option.Option<HistoryData> =>
  Option.some(
    AsyncData.getData(history).pipe(
      Option.map((data) => History.Refreshing({ data })),
      Option.getOrElse(() => AsyncData.Loading()),
    ),
  );

/**
 * The history as a cache Foldkit revalidates: considered only when `when`
 * holds, moved on by `revalidate`, and read for the four weeks ending on the
 * model's day. When there is nothing to do, the model is returned unchanged.
 */
const refreshHistory =
  (
    when: (model: Model) => boolean,
    revalidate: (history: HistoryData) => Option.Option<HistoryData>,
  ): Update.Step<Model, Message, Clients> =>
  (model) =>
    Update.refresh({
      read: (m: Model) => Option.some(m.history).pipe(Option.filter(() => when(m))),
      revalidate,
      write: (m, history) => modifyFields(m, { history: () => history }),
      load: LoadIntervals({ range: historyOf(model.today) }),
    })(model);

/** A page that shows the history opened: load it, or refresh it with the data on screen. A read under way isn't started again. */
const historyOpened = refreshHistory(historyOnScreen, AsyncData.revalidateOrLoad);

/** The history changed in Intervals: refresh it if it holds data. */
const historyChanged = refreshHistory(isSignedIn, AsyncData.revalidate);

/**
 * The four weeks moved: read them again now if they're on screen, or if a read
 * of the old ones is under way (its answer will be ignored, so nothing else
 * would end it). Otherwise the next visit reads them.
 */
const historyMoved = refreshHistory((m) => historyOnScreen(m) || (isSignedIn(m) && AsyncData.isPending(m.history)), reload);

/** The domain refused a live view to this athlete: that view shows why, the others are untouched. */
const REFUSE: { readonly [View in LiveView]: (model: Model) => Model } = {
  plan: (model) => modifyFields(model, { plan: () => AsyncData.fail("notYours") }),
  decision: (model) => modifyFields(model, { decision: () => AsyncData.fail("notYours") }),
  thread: (model) => modifyFields(model, { thread: () => AsyncData.fail("notYours") }),
  profile: (model) => modifyFields(model, { profile: () => AsyncData.fail("notYours") }),
};

/** A watched view whose key changed: what it holds is for the old key until the new snapshot comes. */
const awaitingNext = <A, E>(view: AsyncData.AsyncData<A, E>): AsyncData.AsyncData<A, E> =>
  AsyncData.isIdle(view) ? view : AsyncData.Loading();

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
    // A link to one of the web's pages moves there; any other is the server's (signing in, the privacy policy).
    ClickedLink: ({ request }) =>
      Navigation.UrlRequest.match<Return>(request, {
        Internal: ({ url }) =>
          AppRoute.guards.NotFound(routeOf(url))
            ? { model, commands: [LoadPage({ href: Url.toString(url) })] }
            : { model, commands: [NavigateInternal({ url: Url.toString(url) })] },
        External: ({ href }) => ({ model, commands: [LoadPage({ href })] }),
      }),
    ChangedUrl: ({ url }) => historyOpened(modifyFields(model, { ...clearMessages, route: () => routeOf(url) })),
    CompletedNavigateInternal: () => ({ model }),
    CompletedLoadPage: () => ({ model }),
    ChangedDay: ({ today }) =>
      today === model.today
        ? { model }
        : historyMoved(
            modifyFields(model, {
              today: () => today,
              // Today's decision, and a new month's thread, are other snapshots: wait for them.
              decision: awaitingNext,
              thread: monthOf(today) === monthOf(model.today) ? Function.identity : awaitingNext,
            }),
          ),
    ReceivedPlan: ({ plan }) => read(modifyFields(model, { plan: () => LivePlan.Success({ data: plan }) })),
    ReceivedDecision: ({ decision }) => read(modifyFields(model, { decision: () => LiveDecision.Success({ data: decision }) })),
    // A month that is no longer shown is ignored: its watch has already been replaced.
    ReceivedThread: ({ thread }) =>
      thread.conversationId === conversationOf(model)
        ? read(modifyFields(model, { thread: () => LiveThread.Success({ data: thread }) }))
        : { model },
    ReceivedProfile: ({ profile }) => read(modifyFields(model, { profile: () => LiveProfile.Success({ data: profile }) })),
    RefusedRead: ({ view }) => ({ model: REFUSE[view](model) }),
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
    UpdatedMove: ({ field, value }) => ({
      model: modifyFields(model, { move: (form) => edit(form, MOVE_RULES, field, value) }),
    }),
    SubmittedMove: () => {
      const checked = modifyFields(model, { ...clearMessages, move: (form) => check(form, MOVE_RULES) });
      return Option.match(Option.all({ target: planIdOf(model), input: moveOf(model.move) }), {
        onNone: () => ({ model: checked }),
        onSome: ({ target, input }) => send(checked, Write.MoveSession({ target, input })),
      });
    },
    UpdatedRequirement: ({ field, value }) => ({
      model: modifyFields(model, { requirement: (form) => edit(form, REQUIREMENT_RULES, field, value) }),
    }),
    SubmittedRequirement: () => {
      const checked = modifyFields(model, { ...clearMessages, requirement: (form) => check(form, REQUIREMENT_RULES) });
      return Option.match(Option.all({ target: planIdOf(model), input: requirementOf(model.requirement) }), {
        onNone: () => ({ model: checked }),
        onSome: ({ target, input }) => send(checked, Write.RecordDayRequirement({ target, input })),
      });
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
          succeeded(model, commandId, "Sesión movida.", (m) => modifyFields(m, { move: () => emptyMove })),
        FailedMoveSession: ({ commandId, failure }) => failed(model, commandId, failure, explain(MOVE_REJECTIONS)),
        SucceededRecordDayRequirement: ({ commandId }) =>
          succeeded(model, commandId, "Guardado. El plan ya lo tiene en cuenta.", (m) =>
            modifyFields(m, { requirement: () => emptyRequirement(model.today) }),
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
    UpdatedDeclaration: ({ field, value }) => ({
      model: modifyFields(model, { declaration: (form) => edit(form, DECLARATION_RULES, field, value) }),
    }),
    SubmittedDeclaration: () => {
      if (model.savingDeclaration) return { model };
      const checked = modifyFields(model, { ...clearMessages, declaration: (form) => check(form, DECLARATION_RULES) });
      return Option.match(declarationOf(model.declaration), {
        onNone: () => ({ model: checked }),
        onSome: (declaration) => ({
          model: modifyFields(checked, { savingDeclaration: () => true }),
          commands: [SaveDeclaration({ day: model.today, declaration })],
        }),
      });
    },
    // Today's wellness is part of the history.
    SavedDeclaration: () =>
      historyChanged(
        modifyFields(model, {
          savingDeclaration: () => false,
          declaration: () => emptyDeclaration,
          notice: () => Option.some("Guardado en Intervals.icu."),
        }),
      ),
    FailedDeclaration: ({ problem }) => declarationFailed(model, problem),
  });

// INIT

/** A live view at start: waiting for its first snapshot when signed in, not watched otherwise. */
const watching = (flags: Flags) => (flags.athleteId === null ? AsyncData.Idle() : AsyncData.Loading());

/** The app as it opens on `url`: a reload or a link to Historial or Perfil reads the history at once. */
export const init = (flags: Flags, url: Url.Url): Return =>
  historyOpened(
    Model.make({
      athleteId: flags.athleteId,
      today: flags.today,
      route: routeOf(url),
      commandIds: { session: flags.session, sent: 0 },
      readsOnline: true,
      readRetries: 0,
      plan: watching(flags),
      decision: watching(flags),
      thread: watching(flags),
      profile: watching(flags),
      history: AsyncData.Idle(),
      move: emptyMove,
      requirement: emptyRequirement(flags.today),
      declaration: emptyDeclaration,
      savingDeclaration: false,
      confirmRetire: false,
      inFlight: Option.none(),
      needsReconnect: false,
      notice: Option.none(),
      error: Option.none(),
    }),
  );

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

// VIEW

/** The pages in the navigation: where each lives and what it is called. */
const PAGES: ReadonlyArray<readonly [AppRoute["_tag"], string, string]> = [
  ["Home", homeRouter(), "Hoy"],
  ["Coach", coachRouter(), "Coach"],
  ["Plan", planRouter(), "Plan"],
  ["History", historyRouter(), "Historial"],
  ["Profile", profileRouter(), "Perfil"],
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

/**
 * What a live view shows in each of its states: until its first snapshot comes,
 * or when it is refused, a line says so where its content would be.
 */
const liveContent = <A>(
  h: HtmlBuilder<Message>,
  view: AsyncData.AsyncData<A, typeof ReadProblem.Type>,
  content: (data: A) => ReadonlyArray<Html>,
): ReadonlyArray<Html> =>
  AsyncData.matchData(view, {
    onEmpty: () => [h.p([h.Class("muted"), h.AriaLive("polite")], ["Cargando…"])],
    onFailure: () => [h.p([h.Class("error")], [notYours()])],
    onData: content,
  });

/** Today's decision, once iOS has made one: the card with its note, or a card saying it will come. */
const decisionCard = (model: Model, h: HtmlBuilder<Message>) => {
  const made = AsyncData.getData(model.decision).pipe(
    Option.flatten,
    Option.flatMap((decision) =>
      decision.status === "none" ? Option.none() : Option.map(Option.fromNullishOr(decision.note), (note) => ({ decision, note })),
    ),
  );
  return Option.match(made, {
    onNone: () =>
      h.div([h.Class("card")], [
        h.h2([], ["Hoy"]),
        ...liveContent(h, model.decision, () => [
          h.p([h.Class("muted")], ["La decisión de hoy aparecerá cuando abras Cadencia en el iPhone."]),
        ]),
      ]),
    onSome: ({ decision, note }) =>
      h.div([h.Class("card")], [
        h.h2([], [note.headline]),
        decision.status === "accepted"
          ? pill(h, "Aceptada por el plan", "good")
          : decision.status === "refused"
            ? pill(h, `El plan la rechazó: ${refusalText(decision.refusal)}`, "bad")
            : pill(h, "Esperando al plan", "info"),
        h.p([], [note.body]),
        h.p([], [note.session]),
        ...(note.watch ? [h.p([h.Class("muted")], [note.watch])] : []),
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
      ]),
  });
};

/** The message under a field that fails its rules. */
const errorOf = (field: TextField): Option.Option<string> =>
  FieldValidation.match(field, {
    onNotValidated: () => Option.none(),
    onValidating: () => Option.none(),
    onValid: () => Option.none(),
    onInvalid: ({ errors }) => Option.some(Array.headNonEmpty(errors)),
  });

/**
 * A labelled form control and, when its field fails its rules, the reason
 * under it: the control is marked invalid and described by that reason.
 */
const fieldView = (
  h: HtmlBuilder<Message>,
  id: string,
  label: string,
  field: TextField,
  control: (attributes: ReadonlyArray<Attribute<Message>>) => Html,
) => {
  const error = errorOf(field);
  const errorId = `${id}-error`;
  return h.label([], [
    label,
    control([
      h.Id(id),
      h.Value(field.value),
      h.AriaInvalid(Option.isSome(error)),
      ...Array.fromOption(Option.as(error, h.AriaDescribedBy(errorId))),
    ]),
    ...Array.fromOption(Option.map(error, (reason) => h.span([h.Id(errorId), h.Class("error")], [reason]))),
  ]);
};

const homeView = (model: Model, h: HtmlBuilder<Message>) => [
  decisionCard(model, h),
  h.div([h.Class("card")], [
    h.h2([], ["Próximos 7 días"]),
    ...liveContent(h, model.plan, (plan) => {
      const upcoming = Option.match(plan, {
        onNone: () => [],
        onSome: ({ sessions }) => sessions.filter((s) => s.day >= model.today && s.day <= addDays(model.today, 6)),
      });
      return [
        upcoming.length === 0
          ? h.p([h.Class("muted")], ["No hay sesiones planificadas esta semana."])
          : sessionsTable(h, upcoming, Option.match(plan, { onNone: () => [], onSome: (p) => p.calendarProblems })),
      ];
    }),
  ]),
];

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

const coachView = (model: Model, h: HtmlBuilder<Message>) => [
  h.div([h.Class("card")], [
    h.h2([], ["Conversación de este mes"]),
    h.p([h.Class("muted")], [
      "Para escribir al coach usa Cadencia en el iPhone: la respuesta necesita la IA. Aquí puedes aceptar o descartar lo que te propone.",
    ]),
    ...liveContent(h, model.thread, (thread) =>
      thread.messages.length === 0
        ? [h.p([h.Class("muted")], ["Todavía no hay mensajes este mes."])]
        : thread.messages.map((m) =>
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
        ),
    ),
  ]),
];

const planView = (model: Model, h: HtmlBuilder<Message>) =>
  Option.match(AsyncData.getData(model.plan), {
    onNone: () => [h.div([h.Class("card")], [h.h2([], ["Plan"]), ...liveContent(h, model.plan, () => [])])],
    onSome: (plan) => planCards(model, h, plan),
  });

const planCards = (model: Model, h: HtmlBuilder<Message>, plan: Option.Option<typeof CurrentPlanState.Type>) =>
  Option.match(plan, {
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
                fieldView(h, "move-session", "Sesión", model.move.sessionId, (attributes) =>
                  h.select(
                    [...attributes, h.OnChange((value) => Message.UpdatedMove({ field: "sessionId", value }))],
                    [
                      h.option([h.Value("")], ["Elige…"]),
                      ...plan.sessions
                        .filter((s) => s.day >= model.today && isMovable(s))
                        .map((s) => h.option([h.Value(s.sessionId)], [`${s.day} · ${s.title}`])),
                    ],
                  ),
                ),
                fieldView(h, "move-day", "Nuevo día", model.move.toDay, (attributes) =>
                  h.input([...attributes, h.Type("date"), h.OnInput((value) => Message.UpdatedMove({ field: "toDay", value }))]),
                ),
                h.button([h.Class("primary"), h.Type("submit"), h.Disabled(busy(model))], ["Mover"]),
              ]),
            ]),
            h.div([h.Class("card")], [
              h.h2([], ["Requisito para un día"]),
              h.p([h.Class("muted")], ["El plan nunca te propondrá más minutos de los que indiques, y ajusta la sesión de ese día al momento."]),
              h.form([h.Class("row"), h.OnSubmit(Message.SubmittedRequirement())], [
                fieldView(h, "requirement-day", "Día", model.requirement.day, (attributes) =>
                  h.input([...attributes, h.Type("date"), h.OnInput((value) => Message.UpdatedRequirement({ field: "day", value }))]),
                ),
                fieldView(h, "requirement-minutes", "Máximo de minutos", model.requirement.maxMinutes, (attributes) =>
                  h.input([
                    ...attributes,
                    h.Type("number"),
                    h.Min("0"),
                    h.OnInput((value) => Message.UpdatedRequirement({ field: "maxMinutes", value })),
                  ]),
                ),
                fieldView(h, "requirement-note", "Nota", model.requirement.instructions, (attributes) =>
                  h.input([
                    ...attributes,
                    h.Type("text"),
                    h.OnInput((value) => Message.UpdatedRequirement({ field: "instructions", value })),
                  ]),
                ),
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

const scale = (model: Model, h: HtmlBuilder<Message>, label: string, field: "mood" | "motivation" | "soreness" | "fatigue") =>
  fieldView(h, `declaration-${field}`, label, model.declaration[field], (attributes) =>
    h.select(
      [...attributes, h.OnChange((value) => Message.UpdatedDeclaration({ field, value }))],
      [h.option([h.Value("")], ["—"]), ...["1", "2", "3", "4"].map((n) => h.option([h.Value(n)], [n]))],
    ),
  );

const profileView = (model: Model, h: HtmlBuilder<Message>) => {
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
        scale(model, h, "Ánimo", "mood"),
        scale(model, h, "Motivación", "motivation"),
        scale(model, h, "Agujetas", "soreness"),
        scale(model, h, "Fatiga", "fatigue"),
        fieldView(h, "declaration-weight", "Peso (kg)", model.declaration.weight, (attributes) =>
          h.input([...attributes, h.Type("number"), h.OnInput((value) => Message.UpdatedDeclaration({ field: "weight", value }))]),
        ),
        fieldView(h, "declaration-comments", "Comentario", model.declaration.comments, (attributes) =>
          h.input([...attributes, h.Type("text"), h.OnInput((value) => Message.UpdatedDeclaration({ field: "comments", value }))]),
        ),
        h.button([h.Class("primary"), h.Type("submit"), h.Disabled(model.savingDeclaration)], ["Guardar en Intervals"]),
      ]),
    ]),
    h.div([h.Class("card")], [
      h.h2([], ["Perfil de ciclista"]),
      ...liveContent(h, model.profile, (profile) => [
        Option.match(Option.flatMap(profile, (p) => Option.fromNullishOr(p.report)), {
          onNone: () => h.p([h.Class("muted")], ["Se genera con la IA desde Cadencia para iPhone."]),
          onSome: (report) =>
            h.div([], [
              h.p([], [h.strong([], [report.headline])]),
              h.p([], [report.summary]),
              h.p([h.Class("muted")], [
                `Basado en ${report.rideCount} salidas, ${report.oldest} → ${report.newest}. Confianza: ${report.confidence}.`,
              ]),
            ]),
        }),
      ]),
    ]),
  ];
};

const notFoundView = (h: HtmlBuilder<Message>, path: string) => [
  h.div([h.Class("card")], [
    h.h2([], ["Esta página no existe"]),
    h.p([h.Class("muted")], [`No hay nada en ${path}.`]),
    h.a([h.Href(homeRouter())], ["Volver a hoy"]),
  ]),
];

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
              PAGES.map(([tag, href, label]) =>
                h.a([h.Href(href), ...(model.route._tag === tag ? [h.AriaCurrent("page")] : [])], [label]),
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
          ...AppRoute.match(model.route, {
            Home: () => homeView(model, h),
            Coach: () => coachView(model, h),
            Plan: () => planView(model, h),
            History: () => historyView(model, h),
            Profile: () => profileView(model, h),
            NotFound: ({ path }) => notFoundView(h, path),
          }),
        ]),
  ]),
});
