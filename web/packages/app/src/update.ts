import { HistoryRange } from "@cadencia/athlete/HistoryRange";
import { monthOf } from "@cadencia/coach/Conversation/Conversation.id";
import * as DomainFoldkit from "@alchemy.run/domain/Foldkit";
import * as Function from "effect/Function";
import * as Option from "effect/Option";
import * as Result from "effect/Result";
import { AsyncData, Navigation, Update, Url } from "foldkit";
import { modifyFields } from "foldkit/struct";
import { type Clients, CoachClient, PlanningClient } from "./client.ts";
import {
  backoffSeconds,
  commandFor,
  historyOf,
  LoadIntervals,
  LoadPage,
  NavigateInternal,
  SaveDeclaration,
  WaitToReconnect,
} from "./command.ts";
import {
  check,
  DECLARATION_RULES,
  declarationOf,
  edit,
  emptyDeclaration,
  emptyMove,
  emptyRequirement,
  MOVE_RULES,
  moveOf,
  REQUIREMENT_RULES,
  requirementOf,
} from "./domain/form.ts";
import { INTERVALS_PROBLEMS, IntervalsProblem, SIGNED_OUT } from "./domain/intervalsProblem.ts";
import {
  ACCEPT_REJECTIONS,
  DISMISS_REJECTIONS,
  explain,
  MOVE_REJECTIONS,
  REQUIREMENT_REJECTIONS,
  RETIRE_REJECTIONS,
} from "./domain/rejection.ts";
import { Message } from "./message.ts";
import {
  busy,
  conversationOf,
  History,
  type HistoryData,
  historyOnScreen,
  IntervalsHistory,
  isSignedIn,
  LiveDecision,
  LivePlan,
  LiveProfile,
  LiveThread,
  LiveView,
  Model,
  Write,
} from "./model.ts";
import { AppRoute, hrefOf, routeOf } from "./route.ts";


export const UNKNOWN_OUTCOME = "No sabemos si se guardó: Cadencia no respondió.";

export type Return = Update.Return<Model, Message, Clients>;

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
    historyOutdated: () => false,
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
export const historyOpened = refreshHistory(historyOnScreen, AsyncData.revalidateOrLoad);

/** A read of the history answered; if Intervals changed while it was under way, read it again. */
const settledHistory = (model: Model, result: Result.Result<IntervalsHistory, IntervalsProblem>): Return => {
  const settled = modifyFields(model, {
    history: AsyncData.settle(result),
    historyOutdated: () => false,
    ...(Result.isSuccess(result) ? { needsReconnect: () => false } : {}),
  });
  return model.historyOutdated ? historyReread(settled) : { model: settled };
};

/** Read the history again now, keeping what's on screen. */
const historyReread = refreshHistory(isSignedIn, reload);

/**
 * The history changed in Intervals: refresh it if it holds data. A read under
 * way may have been answered before the change, so it is read again once it
 * settles.
 */
const historyChanged: Update.Step<Model, Message, Clients> = (model) =>
  isSignedIn(model) && AsyncData.isPending(model.history)
    ? { model: modifyFields(model, { historyOutdated: () => true }) }
    : refreshHistory(isSignedIn, AsyncData.revalidate)(model);

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
    // Starting again asks the server who is signed in once more.
    ClickedRetryStart: () => ({ model, commands: [LoadPage({ href: hrefOf(model.route) })] }),
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
          : settledHistory(model, result),
    ClickedAcceptIntent: ({ conversationId, messageId }) =>
      send(model, Write.AcceptIntent({ target: conversationId, input: { messageId, today: model.today } })),
    ClickedDismissIntent: ({ conversationId, messageId }) =>
      send(model, Write.DismissIntent({ target: conversationId, input: { messageId } })),
    // A form is closed while its write is under way, on screen and here: a success clears only what was sent.
    UpdatedMove: ({ field, value }) => ({
      model: busy(model) ? model : modifyFields(model, { move: (form) => edit(form, MOVE_RULES, field, value) }),
    }),
    SubmittedMove: () => {
      const checked = modifyFields(model, { ...clearMessages, move: (form) => check(form, MOVE_RULES) });
      return Option.match(Option.all({ target: planIdOf(model), input: moveOf(model.move) }), {
        onNone: () => ({ model: checked }),
        onSome: ({ target, input }) => send(checked, Write.MoveSession({ target, input })),
      });
    },
    UpdatedRequirement: ({ field, value }) => ({
      model: busy(model)
        ? model
        : modifyFields(model, { requirement: (form) => edit(form, REQUIREMENT_RULES, field, value) }),
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
      model: model.savingDeclaration
        ? model
        : modifyFields(model, { declaration: (form) => edit(form, DECLARATION_RULES, field, value) }),
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
