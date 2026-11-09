import { ActivitySummary } from "@cadencia/athlete/ActivitySummary";
import { AthleteMeasures } from "@cadencia/athlete/AthleteMeasures";
import { HistoryRange } from "@cadencia/athlete/HistoryRange";
import { WellnessDay, WellnessDeclaration } from "@cadencia/athlete/Wellness";
import { addDays, Day } from "@cadencia/kernel/Calendar/Day";
import * as Duration from "effect/Duration";
import * as Effect from "effect/Effect";
import * as Data from "effect/Data";
import * as HttpClient from "effect/http/HttpClient";
import * as HttpClientRequest from "effect/http/HttpClientRequest";
import * as HttpClientResponse from "effect/http/HttpClientResponse";
import * as Schema from "effect/Schema";
import { Command, Http, Navigation } from "foldkit";
import { type Clients, CoachClient, PlanningClient } from "./client.ts";
import { IntervalsProblem, intervalsProblemOf } from "./domain/intervalsProblem.ts";
import { Message } from "./message.ts";
import { Write } from "./model.ts";

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
export const historyOf = (today: Day): HistoryRange => ({ oldest: addDays(today, -27), newest: today });
