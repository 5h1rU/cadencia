import { IntervalsActivityId } from "@cadencia/athlete/Activity.id";
import { EvidenceSnapshot } from "@cadencia/athlete/Evidence";
import { Bpm, FtpWatts, HrvMs, Kilograms, Rpe, TrainingLoad, Watts, WellnessScale } from "@cadencia/athlete/Measures";
import { AthleteCoachApi } from "@cadencia/coach/AthleteCoachApi.api";
import { CoachNote, Refusal, type RefusalReason } from "@cadencia/coach/CoachShape";
import { ModelName } from "@cadencia/coach/CoachText";
import { ConversationId } from "@cadencia/coach/Conversation/Conversation.id";
import { ThreadMessage } from "@cadencia/coach/Conversation/ConversationThread.view";
import { MessageId } from "@cadencia/coach/Conversation/Message.id";
import { DailyDecisionId } from "@cadencia/coach/DailyDecision/DailyDecision.id";
import { RiderReport } from "@cadencia/coach/RiderProfile/RiderReport";
import { AthleteId } from "@cadencia/identity/Athlete.id";
import { addDays, Day } from "@cadencia/kernel/Calendar/Day";
import { PlanId } from "@cadencia/kernel/Plan.id";
import { Paragraph, Title } from "@cadencia/kernel/Text";
import { Minutes, Seconds } from "@cadencia/kernel/Training/Units";
import { Workout } from "@cadencia/kernel/Training/Workout";
import { AthletePlanningApi } from "@cadencia/planning/AthletePlanningApi.api";
import { DayRequirement, Phase, PlannedSession } from "@cadencia/planning/Plan/PlanShape";
import { SessionId } from "@cadencia/planning/Plan/Session.id";
import type * as Domain from "@alchemy.run/domain";
import * as DomainFoldkit from "@alchemy.run/domain/Foldkit";
import * as Effect from "effect/Effect";
import * as Option from "effect/Option";
import * as Schema from "effect/Schema";
import { Command, Subscription, type Update } from "foldkit";
import type { Document, HtmlBuilder } from "foldkit/html";
import { defineMessageUnion } from "foldkit/message";
import { modifyFields } from "foldkit/struct";

type Clients = Domain.Api.ClientKey<"AthletePlanningApi"> | Domain.Api.ClientKey<"AthleteCoachApi">;
export const PlanningClient = DomainFoldkit.make(AthletePlanningApi);
export const CoachClient = DomainFoldkit.make(AthleteCoachApi);

// MODEL

export const Section = Schema.Literals(["home", "coach", "plan", "history", "profile"]);
export type Section = typeof Section.Type;

const PlanView = Schema.Struct({
  planId: PlanId,
  status: Schema.Literals(["none", "active", "retired"]),
  title: Schema.NullOr(Title),
  startDay: Schema.NullOr(Day),
  endDay: Schema.NullOr(Day),
  phases: Schema.Array(Phase),
  sessions: Schema.Array(PlannedSession),
  requirements: Schema.Array(DayRequirement),
});
type PlanView = typeof PlanView.Type;

const DecisionView = Schema.Struct({
  status: Schema.Literals(["none", "pending", "accepted", "refused"]),
  workout: Schema.NullOr(Workout),
  note: Schema.NullOr(CoachNote),
  evidence: Schema.NullOr(EvidenceSnapshot),
  model: Schema.NullOr(ModelName),
  refusal: Schema.NullOr(Refusal),
});
type DecisionView = typeof DecisionView.Type;

const ProfileView = Schema.Struct({ report: Schema.NullOr(RiderReport), model: Schema.NullOr(ModelName) });

/**
 * The fields the server passes through from Intervals.icu. `name` and
 * `start_date_local` stay Intervals' own text: any app, or the athlete, wrote them.
 */
export const ActivityRow = Schema.Struct({
  id: IntervalsActivityId,
  name: Schema.optional(Schema.NullOr(Schema.String)),
  start_date_local: Schema.optional(Schema.NullOr(Schema.String)),
  moving_time: Schema.optional(Schema.NullOr(Seconds)),
  icu_training_load: Schema.optional(Schema.NullOr(TrainingLoad)),
  icu_weighted_avg_watts: Schema.optional(Schema.NullOr(Watts)),
  icu_rpe: Schema.optional(Schema.NullOr(Rpe)),
});
export type ActivityRow = typeof ActivityRow.Type;

export const WellnessRow = Schema.Struct({
  id: Day,
  ctl: Schema.optional(Schema.NullOr(TrainingLoad)),
  atl: Schema.optional(Schema.NullOr(TrainingLoad)),
  weight: Schema.optional(Schema.NullOr(Kilograms)),
  hrv: Schema.optional(Schema.NullOr(HrvMs)),
  restingHR: Schema.optional(Schema.NullOr(Bpm)),
});
export type WellnessRow = typeof WellnessRow.Type;

export const AthleteRow = Schema.Struct({
  name: Schema.NullOr(Schema.String),
  weight: Schema.NullOr(Kilograms),
  ftp: Schema.NullOr(FtpWatts),
});

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
  today: Day,
  section: Section,
  commandIds: DomainFoldkit.CommandIds,
  plan: Schema.Option(PlanView),
  decision: Schema.Option(DecisionView),
  thread: Schema.Array(ThreadMessage),
  profile: Schema.Option(ProfileView),
  activities: Schema.Array(ActivityRow),
  wellness: Schema.Array(WellnessRow),
  athlete: Schema.Option(AthleteRow),
  move: Schema.Struct({ sessionId: Schema.String, toDay: Schema.String }),
  requirement: Schema.Struct({ day: Schema.String, maxMinutes: Schema.String, instructions: Schema.String }),
  declaration: Declaration,
  confirmRetire: Schema.Boolean,
  notice: Schema.Option(Schema.String),
  error: Schema.Option(Schema.String),
});
export type Model = typeof Model.Type;

// MESSAGE

/** The writes the web makes, none of which needs AI. */
const WriteAction = Schema.Literals(["acceptIntent", "dismissIntent", "moveSession", "requirement", "retire", "declaration"]);
type WriteAction = typeof WriteAction.Type;

export const Message = defineMessageUnion({
  ClickedSection: { section: Section },
  ReceivedPlan: { plan: Schema.Option(PlanView) },
  ReceivedDecision: { decision: Schema.Option(DecisionView) },
  ReceivedThread: { messages: Schema.Array(ThreadMessage) },
  ReceivedProfile: { profile: Schema.Option(ProfileView) },
  FailedRead: { reason: Schema.String },
  LoadedIntervals: {
    activities: Schema.Array(ActivityRow),
    wellness: Schema.Array(WellnessRow),
    athlete: Schema.Option(AthleteRow),
  },
  FailedIntervals: { reason: Schema.String },
  ClickedAcceptIntent: { messageId: MessageId },
  ClickedDismissIntent: { messageId: MessageId },
  ChangedMove: { field: Schema.Literals(["sessionId", "toDay"]), value: Schema.String },
  SubmittedMove: {},
  ChangedRequirement: { field: Schema.Literals(["day", "maxMinutes", "instructions"]), value: Schema.String },
  SubmittedRequirement: {},
  ClickedRetire: {},
  ClickedConfirmRetire: {},
  ClickedCancelRetire: {},
  ChangedDeclaration: {
    field: Schema.Literals(["mood", "motivation", "soreness", "fatigue", "weight", "comments"]),
    value: Schema.String,
  },
  SubmittedDeclaration: {},
  CompletedDeclaration: {},
  CompletedWrite: { action: WriteAction },
  FailedWrite: { action: WriteAction, reason: Schema.String },
});
export type Message = typeof Message.Type;

// COMMAND

const getJson = (path: string) =>
  Effect.tryPromise(async () => {
    const response = await fetch(path, { credentials: "same-origin" });
    if (!response.ok) throw new Error(`${path}: ${response.status}`);
    return (await response.json()) as unknown;
  });

export const LoadIntervals = Command.define("LoadIntervals", {
  args: { today: Day },
  messages: [Message.LoadedIntervals, Message.FailedIntervals],
  execute: ({ today }) => {
    const range = `oldest=${addDays(today, -27)}&newest=${today}`;
    return Effect.all({
      activities: getJson(`/api/intervals/activities?${range}`).pipe(
        Effect.flatMap(Schema.decodeUnknownEffect(Schema.Array(ActivityRow))),
      ),
      wellness: getJson(`/api/intervals/wellness?${range}`).pipe(
        Effect.flatMap(Schema.decodeUnknownEffect(Schema.Array(WellnessRow))),
      ),
      athlete: getJson("/api/intervals/athlete").pipe(
        Effect.flatMap(Schema.decodeUnknownEffect(AthleteRow)),
        Effect.option,
      ),
    }).pipe(
      Effect.map((loaded) => Message.LoadedIntervals(loaded)),
      Effect.catch(() =>
        Effect.succeed(Message.FailedIntervals({ reason: "No se pudo leer Intervals.icu. Vuelve a intentarlo." })),
      ),
    );
  },
});

/** What the athlete may declare from the web, each in its Intervals unit. */
export const WellnessDeclaration = Schema.Struct({
  mood: Schema.optional(WellnessScale),
  motivation: Schema.optional(WellnessScale),
  soreness: Schema.optional(WellnessScale),
  fatigue: Schema.optional(WellnessScale),
  weight: Schema.optional(Kilograms),
  comments: Schema.optional(Paragraph),
});
export type WellnessDeclaration = typeof WellnessDeclaration.Type;

/** The form, decoded: empty fields are left out; anything else must be valid. */
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

export const SaveDeclaration = Command.define("SaveDeclaration", {
  args: { today: Day, declaration: WellnessDeclaration },
  messages: [Message.CompletedDeclaration, Message.FailedWrite],
  execute: ({ today, declaration }) =>
    Effect.tryPromise(async () => {
      const body = Schema.encodeSync(WellnessDeclaration)(declaration);
      const response = await fetch(`/api/intervals/wellness/${today}`, {
        method: "PUT",
        credentials: "same-origin",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(body),
      });
      if (!response.ok) throw new Error(String(response.status));
    }).pipe(
      Effect.as(Message.CompletedDeclaration()),
      Effect.catch(() =>
        Effect.succeed(Message.FailedWrite({ action: "declaration", reason: "Intervals.icu no guardó los datos." })),
      ),
    ),
});

/** A domain command's result as a plain outcome: done, or the rejection's name. */
const outcome =
  (action: WriteAction) =>
  (result: { readonly _tag: string }): Message => {
    if (!result._tag.startsWith("Failed")) return Message.CompletedWrite({ action });
    const failure = (result as { readonly failure?: unknown }).failure as
      | { readonly _tag: string; readonly rejection?: { readonly _tag: string } }
      | undefined;
    const reason =
      failure?._tag === "Rejected" && failure.rejection ? failure.rejection._tag : (failure?._tag ?? "Unknown");
    return Message.FailedWrite({ action, reason });
  };

// UPDATE

const REASONS: Record<string, string> = {
  NotYours: "No tienes permiso para cambiar esto.",
  PlanNotActive: "El plan no está activo.",
  SessionNotFound: "Esa sesión ya no existe en el plan.",
  DayOutsidePlan: "El día está fuera de las fechas del plan.",
  DayTaken: "Ese día ya tiene otra sesión.",
  NoOpenIntent: "Esa propuesta ya no está pendiente.",
  Unknown: "No sabemos si se guardó. Vuelve a intentarlo.",
};

const reasonText = (reason: string) => REASONS[reason] ?? reason;

const allocate = (model: Model) => DomainFoldkit.next(model.commandIds);

const send = (
  model: Model,
  build: (commandId: string) => Command.Command<Message, never, Clients>,
): Update.Return<Model, Message, Clients> => {
  const { commandId, commandIds } = allocate(model);
  return {
    model: modifyFields(model, { commandIds: () => commandIds, error: () => Option.none(), notice: () => Option.none() }),
    commands: [build(commandId)],
  };
};

const planIdOf = (model: Model) =>
  Option.flatMap(model.plan, (plan) => (plan.status === "active" ? Option.some(plan.planId) : Option.none()));

/** Keys are only read while signed in; a placeholder keeps them well-formed before that. */
const owner = (model: Model) => model.athleteId ?? "signed-out";
const conversationOf = (model: Model) => ConversationId.make(`${owner(model)}:${model.today.slice(0, 7)}`);

export const update = (model: Model, message: Message): Update.Return<Model, Message, Clients> =>
  Message.match<Update.Return<Model, Message, Clients>>(message, {
    ClickedSection: ({ section }) => ({
      model: modifyFields(model, { section: () => section, error: () => Option.none(), notice: () => Option.none() }),
      commands:
        (section === "history" || section === "profile") && model.athleteId !== null
          ? [LoadIntervals({ today: model.today })]
          : [],
    }),
    ReceivedPlan: ({ plan }) => ({ model: modifyFields(model, { plan: () => plan }) }),
    ReceivedDecision: ({ decision }) => ({ model: modifyFields(model, { decision: () => decision }) }),
    ReceivedThread: ({ messages }) => ({ model: modifyFields(model, { thread: () => messages }) }),
    ReceivedProfile: ({ profile }) => ({ model: modifyFields(model, { profile: () => profile }) }),
    FailedRead: ({ reason }) => ({ model: modifyFields(model, { error: () => Option.some(reasonText(reason)) }) }),
    LoadedIntervals: ({ activities, wellness, athlete }) => ({
      model: modifyFields(model, { activities: () => activities, wellness: () => wellness, athlete: () => athlete }),
    }),
    FailedIntervals: ({ reason }) => ({ model: modifyFields(model, { error: () => Option.some(reason) }) }),
    ClickedAcceptIntent: ({ messageId }) =>
      send(model, (commandId) =>
        Command.mapMessage(
          CoachClient.AcceptIntent({ target: conversationOf(model), input: { messageId }, commandId }),
          outcome("acceptIntent"),
        ),
      ),
    ClickedDismissIntent: ({ messageId }) =>
      send(model, (commandId) =>
        Command.mapMessage(
          CoachClient.DismissIntent({ target: conversationOf(model), input: { messageId }, commandId }),
          outcome("dismissIntent"),
        ),
      ),
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
      return send(model, (commandId) =>
        Command.mapMessage(
          PlanningClient.MoveSession({
            target: planId.value,
            input: { sessionId: sessionId.value, toDay: toDay.value },
            commandId,
          }),
          outcome("moveSession"),
        ),
      );
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
        return { model: modifyFields(model, { error: () => Option.some("Indica un día y, si quieres, un máximo de minutos.") }) };
      }
      return send(model, (commandId) =>
        Command.mapMessage(
          PlanningClient.RecordDayRequirement({
            target: planId.value,
            input: { day: day.value, instructions: instructions.value, maxMinutes: minutes.value },
            commandId,
          }),
          outcome("requirement"),
        ),
      );
    },
    ClickedRetire: () => ({ model: modifyFields(model, { confirmRetire: () => true }) }),
    ClickedCancelRetire: () => ({ model: modifyFields(model, { confirmRetire: () => false }) }),
    ClickedConfirmRetire: () => {
      const planId = planIdOf(model);
      if (Option.isNone(planId)) return { model };
      const next = send(model, (commandId) =>
        Command.mapMessage(PlanningClient.RetirePlan({ target: planId.value, input: {}, commandId }), outcome("retire")),
      );
      return { ...next, model: modifyFields(next.model, { confirmRetire: () => false }) };
    },
    ChangedDeclaration: ({ field, value }) => ({
      model: modifyFields(model, { declaration: (d) => ({ ...d, [field]: value }) }),
    }),
    SubmittedDeclaration: () =>
      Option.match(declarationOf(model.declaration), {
        onNone: () => ({
          model: modifyFields(model, {
            error: () => Option.some("Revisa los datos: las escalas van de 1 a 4 y el peso, de 20 a 350 kg."),
          }),
        }),
        onSome: (declaration) => ({
          model: modifyFields(model, { error: () => Option.none(), notice: () => Option.none() }),
          commands: [SaveDeclaration({ today: model.today, declaration })],
        }),
      }),
    CompletedDeclaration: () => ({
      model: modifyFields(model, {
        declaration: () => emptyDeclaration,
        notice: () => Option.some("Guardado en Intervals.icu."),
      }),
    }),
    CompletedWrite: ({ action }) => ({
      model: modifyFields(model, {
        notice: () =>
          Option.some(
            action === "acceptIntent"
              ? "Propuesta aceptada. El plan la aplicará si cumple sus reglas."
              : action === "retire"
                ? "Plan retirado."
                : "Hecho.",
          ),
      }),
    }),
    FailedWrite: ({ reason }) => ({ model: modifyFields(model, { error: () => Option.some(reasonText(reason)) }) }),
  });

// INIT

export const init = (flags: Flags): Update.Return<Model, Message, Clients> => ({
  model: Model.make({
    athleteId: flags.athleteId,
    today: flags.today,
    section: "home",
    commandIds: { session: flags.session, sent: 0 },
    plan: Option.none(),
    decision: Option.none(),
    thread: [],
    profile: Option.none(),
    activities: [],
    wellness: [],
    athlete: Option.none(),
    move: { sessionId: "", toDay: "" },
    requirement: { day: flags.today, maxMinutes: "", instructions: "" },
    declaration: emptyDeclaration,
    confirmRetire: false,
    notice: Option.none(),
    error: Option.none(),
  }),
});

// SUBSCRIPTION

const signedIn = (model: Model) => model.athleteId !== null;

export const subscriptions = Subscription.make<Model, Message, Clients>()(() => ({
  plan: PlanningClient.CurrentPlan.watch({
    key: (model: Model) => AthleteId.make(owner(model)),
    isEnabled: signedIn,
    toMessage: ({ state }): Message =>
      Message.ReceivedPlan({
        plan: Option.flatMap(state, (p) =>
          p.planId === null ? Option.none() : Option.some({ ...p, planId: p.planId }),
        ),
      }),
    onFailure: (error): Message => Message.FailedRead({ reason: error._tag }),
    onDefect: (): Message => Message.FailedRead({ reason: "Unknown" }),
  }),
  decision: CoachClient.TodayDecision.watch({
    key: (model: Model) => DailyDecisionId.make(`${owner(model)}:${model.today}`),
    isEnabled: signedIn,
    toMessage: ({ state }): Message => Message.ReceivedDecision({ decision: state }),
    onFailure: (error): Message => Message.FailedRead({ reason: error._tag }),
    onDefect: (): Message => Message.FailedRead({ reason: "Unknown" }),
  }),
  thread: CoachClient.ConversationThread.watch({
    key: conversationOf,
    isEnabled: signedIn,
    toMessage: ({ state }): Message =>
      Message.ReceivedThread({ messages: Option.match(state, { onNone: () => [], onSome: (t) => t.messages }) }),
    onFailure: (error): Message => Message.FailedRead({ reason: error._tag }),
    onDefect: (): Message => Message.FailedRead({ reason: "Unknown" }),
  }),
  profile: CoachClient.RiderProfileCard.watch({
    key: (model: Model) => AthleteId.make(owner(model)),
    isEnabled: signedIn,
    toMessage: ({ state }): Message => Message.ReceivedProfile({ profile: state }),
    onFailure: (error): Message => Message.FailedRead({ reason: error._tag }),
    onDefect: (): Message => Message.FailedRead({ reason: "Unknown" }),
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

const KIND: Record<string, string> = {
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

const STATUS: Record<string, readonly [string, string]> = {
  provisional: ["Provisional", "info"],
  concrete: ["Concretada", "info"],
  published: ["En Intervals", "good"],
  skipped: ["Omitida", "warn"],
  changedInIntervals: ["Cambiada en Intervals", "warn"],
  removedInIntervals: ["Borrada en Intervals", "bad"],
};

const REFUSALS: Record<RefusalReason, string> = {
  planNotActive: "el plan no está activo",
  dayNotPlanned: "ese día no tiene sesión",
  dayOutsidePlan: "el día está fuera del plan",
  dayTaken: "ese día ya tiene sesión",
  sessionNotFound: "la sesión ya no existe",
  availabilityExceeded: "supera el tiempo disponible",
  intensityAfterHardTraining: "hay entrenamiento duro el mismo día o el anterior",
  hardensPlan: "endurecía una sesión suave del plan",
  purposeMismatch: "no encaja con el propósito de la sesión",
  invalidPlan: "el borrador no es un plan válido",
  planAlreadyExists: "el plan ya existe",
  notYours: "no tienes permiso",
};

const refusalText = (refusal: Refusal | null) => (refusal === null ? "" : REFUSALS[refusal.reason]);

const minutesOf = (workout: Workout) => Math.round(workout.steps.reduce((s, step) => s + step.durationSeconds, 0) / 60);

const pill = (h: HtmlBuilder<Message>, text: string, tone: string) => h.span([h.Class(`pill ${tone}`)], [text]);

const homeView = (model: Model, h: HtmlBuilder<Message>) => {
  const decision = Option.getOrNull(model.decision);
  const upcoming = Option.match(model.plan, {
    onNone: () => [],
    onSome: (plan) => plan.sessions.filter((s) => s.day >= model.today && s.day <= addDays(model.today, 6)),
  });
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
          ...(decision.workout
            ? [h.p([h.Class("muted")], [`${KIND[decision.workout.kind] ?? decision.workout.kind} · ${minutesOf(decision.workout)} min`])]
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
        : sessionsTable(h, upcoming),
    ]),
  ];
};

const sessionsTable = (h: HtmlBuilder<Message>, sessions: ReadonlyArray<PlannedSession>) =>
  h.div([h.Class("scroll")], [
    h.table([], [
      h.thead([], [h.tr([], [h.th([], ["Día"]), h.th([], ["Sesión"]), h.th([], ["Min"]), h.th([], ["Estado"])])]),
      h.tbody(
        [],
        sessions.map((s) => {
          const [label, tone] = STATUS[s.status] ?? [s.status, "info"];
          return h.keyed("tr")(s.sessionId, [], [
            h.td([], [s.day]),
            h.td([], [`${s.workout?.name ?? s.title} · ${KIND[s.kind] ?? s.kind}`]),
            h.td([], [String(s.workout ? minutesOf(s.workout) : s.targetMinutes)]),
            h.td([], [pill(h, label, tone)]),
          ]);
        }),
      ),
    ]),
  ]);

const coachView = (model: Model, h: HtmlBuilder<Message>) => [
  h.div([h.Class("card")], [
    h.h2([], ["Conversación de este mes"]),
    h.p([h.Class("muted")], ["Para escribir al coach usa Cadencia en el iPhone: la respuesta necesita la IA. Aquí puedes aceptar o descartar lo que te propone."]),
    ...(model.thread.length === 0
      ? [h.p([h.Class("muted")], ["Todavía no hay mensajes este mes."])]
      : model.thread.map((m) =>
          h.keyed("div")(m.messageId, [h.Class(`message ${m.role}`)], [
            h.p([], [m.text]),
            ...(m.intent
              ? [
                  h.p([h.Class("muted")], [`Propuesta: ${m.intent.summary}`]),
                  m.intentStatus === "proposed"
                    ? h.div([h.Class("row")], [
                        h.button([h.Class("primary"), h.OnClick(Message.ClickedAcceptIntent({ messageId: m.messageId }))], ["Aceptar"]),
                        h.button([h.Class("secondary"), h.OnClick(Message.ClickedDismissIntent({ messageId: m.messageId }))], ["Descartar"]),
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
        h.p([h.Class("muted")], [`${plan.startDay ?? ""} → ${plan.endDay ?? ""}`]),
        h.ul([], plan.phases.map((p) => h.li([], [`Semanas ${p.startWeek}–${p.endWeek}: ${p.summary}`]))),
      ]),
      h.div([h.Class("card")], [h.h2([], ["Sesiones"]), sessionsTable(h, plan.sessions)]),
      ...(plan.status === "active"
        ? [
            h.div([h.Class("card")], [
              h.h2([], ["Mover una sesión"]),
              h.form([h.Class("row"), h.OnSubmit(Message.SubmittedMove())], [
                h.label([], [
                  "Sesión",
                  h.select(
                    [h.Value(model.move.sessionId), h.OnChange((value) => Message.ChangedMove({ field: "sessionId", value }))],
                    [
                      h.option([h.Value("")], ["Elige…"]),
                      ...plan.sessions
                        .filter((s) => s.day >= model.today)
                        .map((s) => h.option([h.Value(s.sessionId)], [`${s.day} · ${s.title}`])),
                    ],
                  ),
                ]),
                h.label([], [
                  "Nuevo día",
                  h.input([h.Type("date"), h.Value(model.move.toDay), h.OnInput((value) => Message.ChangedMove({ field: "toDay", value }))]),
                ]),
                h.button([h.Class("primary"), h.Type("submit")], ["Mover"]),
              ]),
            ]),
            h.div([h.Class("card")], [
              h.h2([], ["Requisito para un día"]),
              h.p([h.Class("muted")], ["El plan nunca te propondrá más minutos de los que indiques."]),
              h.form([h.Class("row"), h.OnSubmit(Message.SubmittedRequirement())], [
                h.label([], [
                  "Día",
                  h.input([h.Type("date"), h.Value(model.requirement.day), h.OnInput((value) => Message.ChangedRequirement({ field: "day", value }))]),
                ]),
                h.label([], [
                  "Máximo de minutos",
                  h.input([h.Type("number"), h.Min("0"), h.Value(model.requirement.maxMinutes), h.OnInput((value) => Message.ChangedRequirement({ field: "maxMinutes", value }))]),
                ]),
                h.label([], [
                  "Nota",
                  h.input([h.Type("text"), h.Value(model.requirement.instructions), h.OnInput((value) => Message.ChangedRequirement({ field: "instructions", value }))]),
                ]),
                h.button([h.Class("primary"), h.Type("submit")], ["Guardar"]),
              ]),
            ]),
            h.div([h.Class("card")], [
              h.h2([], ["Retirar el plan"]),
              h.p([h.Class("muted")], ["Sus próximas sesiones salen del calendario de Intervals.icu."]),
              model.confirmRetire
                ? h.div([h.Class("row")], [
                    h.button([h.Class("primary"), h.OnClick(Message.ClickedConfirmRetire())], ["Sí, retirar el plan"]),
                    h.button([h.Class("secondary"), h.OnClick(Message.ClickedCancelRetire())], ["Cancelar"]),
                  ])
                : h.button([h.Class("secondary"), h.OnClick(Message.ClickedRetire())], ["Retirar el plan"]),
            ]),
          ]
        : []),
    ],
  });

const historyView = (model: Model, h: HtmlBuilder<Message>) => {
  const latest = model.wellness.at(-1);
  return [
    h.div([h.Class("card")], [
      h.h2([], ["Forma"]),
      latest && latest.ctl != null && latest.atl != null
        ? h.p([], [`Forma (CTL) ${latest.ctl.toFixed(0)} · Fatiga (ATL) ${latest.atl.toFixed(0)} · Balance ${(latest.ctl - latest.atl).toFixed(0)}`])
        : h.p([h.Class("muted")], ["Sin datos de bienestar en las últimas cuatro semanas."]),
    ]),
    h.div([h.Class("card")], [
      h.h2([], ["Actividades de las últimas cuatro semanas"]),
      model.activities.length === 0
        ? h.p([h.Class("muted")], ["No hay actividades en Intervals.icu en estas fechas."])
        : h.div([h.Class("scroll")], [
            h.table([], [
              h.thead([], [h.tr([], [h.th([], ["Fecha"]), h.th([], ["Actividad"]), h.th([], ["Min"]), h.th([], ["Carga"]), h.th([], ["NP"])])]),
              h.tbody(
                [],
                [...model.activities].reverse().map((a) =>
                  h.keyed("tr")(a.id, [], [
                    h.td([], [(a.start_date_local ?? "").slice(0, 10)]),
                    h.td([], [a.name ?? ""]),
                    h.td([], [a.moving_time != null ? String(Math.round(a.moving_time / 60)) : ""]),
                    h.td([], [a.icu_training_load != null ? String(a.icu_training_load) : ""]),
                    h.td([], [a.icu_weighted_avg_watts != null ? `${a.icu_weighted_avg_watts} W` : ""]),
                  ]),
                ),
              ),
            ]),
          ]),
    ]),
  ];
};

const scale = (h: HtmlBuilder<Message>, label: string, field: "mood" | "motivation" | "soreness" | "fatigue", value: string) =>
  h.label([], [
    label,
    h.select(
      [h.Value(value), h.OnChange((v) => Message.ChangedDeclaration({ field, value: v }))],
      [h.option([h.Value("")], ["—"]), ...["1", "2", "3", "4"].map((n) => h.option([h.Value(n)], [n]))],
    ),
  ]);

const profileView = (model: Model, h: HtmlBuilder<Message>) => {
  const athlete = Option.getOrNull(model.athlete);
  const report = Option.getOrNull(Option.flatMap(model.profile, (p) => Option.fromNullishOr(p.report)));
  return [
    h.div([h.Class("card")], [
      h.h2([], [athlete?.name ?? "Tu perfil"]),
      h.p([], [`Peso: ${athlete?.weight != null ? `${athlete.weight} kg` : "—"} · FTP: ${athlete?.ftp != null ? `${athlete.ftp} W` : "—"}`]),
      h.p([h.Class("muted")], ["Estos datos viven en Intervals.icu."]),
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
          h.input([h.Type("number"), h.Value(model.declaration.weight), h.OnInput((value) => Message.ChangedDeclaration({ field: "weight", value }))]),
        ]),
        h.label([], [
          "Comentario",
          h.input([h.Type("text"), h.Value(model.declaration.comments), h.OnInput((value) => Message.ChangedDeclaration({ field: "comments", value }))]),
        ]),
        h.button([h.Class("primary"), h.Type("submit")], ["Guardar en Intervals"]),
      ]),
    ]),
    h.div([h.Class("card")], [
      h.h2([], ["Perfil de ciclista"]),
      report === null
        ? h.p([h.Class("muted")], ["Se genera con la IA desde Cadencia para iPhone."])
        : h.div([], [
            h.p([], [h.strong([], [report.headline])]),
            h.p([], [report.summary]),
            h.p([h.Class("muted")], [`Basado en ${report.rideCount} salidas, ${report.oldest} → ${report.newest}. Confianza: ${report.confidence}.`]),
          ]),
    ]),
  ];
};

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
            h.p([], ["Cadencia usa Intervals.icu como fuente de verdad: tus actividades, tu bienestar y tu calendario siguen allí."]),
            h.a([h.Class("connect"), h.Href("/auth/intervals/start")], ["Conectar con Intervals.icu"]),
          ]),
        ]
      : [
          ...Option.match(model.error, { onNone: () => [], onSome: (e) => [h.p([h.Class("error")], [e])] }),
          ...Option.match(model.notice, { onNone: () => [], onSome: (n) => [h.p([h.Class("muted")], [n])] }),
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
