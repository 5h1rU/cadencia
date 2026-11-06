import { AthleteId, ownerOf } from "@cadencia/identity/Athlete.id";
import { NotYours } from "@cadencia/identity/NotYours.rejection";
import { mustOwn } from "@cadencia/identity/owns";
import { Session } from "@cadencia/identity/Session.middleware";
import * as Domain from "@alchemy.run/domain";
import * as Effect from "effect/Effect";
import * as Schema from "effect/Schema";
import { Refusal } from "./CoachShape.ts";
import { Headline } from "./CoachText.ts";
import { Conversation } from "./Conversation/Conversation.aggregate.ts";
import { ConversationId } from "./Conversation/Conversation.id.ts";
import { Count } from "./Counts.ts";
import { DailyDecision } from "./DailyDecision/DailyDecision.aggregate.ts";
import { DailyDecisionId } from "./DailyDecision/DailyDecision.id.ts";
import { RiderProfile } from "./RiderProfile/RiderProfile.aggregate.ts";

/** Where an entry of the timeline came from, to open its detail. */
export const TimelineSource = Schema.Union([
  Schema.TaggedStruct("DailyDecision", { id: DailyDecisionId }),
  Schema.TaggedStruct("Conversation", { id: ConversationId }),
  Schema.TaggedStruct("RiderProfile", { id: AthleteId }),
]);
export type TimelineSource = typeof TimelineSource.Type;

/** One thing the coach did, for the athlete's history. */
export class TimelineEntry extends Domain.Event("TimelineEntry", {
  at: Schema.DateTimeUtc,
  source: TimelineSource,
  entry: Schema.Union([
    Schema.TaggedStruct("Decision", { headline: Headline }),
    Schema.TaggedStruct("Accepted", {}),
    Schema.TaggedStruct("Refused", { refusal: Refusal }),
    Schema.TaggedStruct("Reply", {}),
    Schema.TaggedStruct("Profile", { headline: Headline }),
  ]),
}) {}

/** Everything the coach did for an athlete, newest last. Page through it with `list`. */
export class CoachTimeline extends Domain.View("CoachTimeline", {
  from: [DailyDecision, Conversation, RiderProfile],
  key: AthleteId,
  middleware: [Session],
  rejects: [NotYours],
  keyOf: {
    DailyDecision: ({ source }) => ownerOf(source.id),
    Conversation: ({ source }) => ownerOf(source.id),
    RiderProfile: ({ source }) => source.id,
  },
  state: Schema.Struct({ entries: Count }),
  initial: { entries: Count.make(0) },
  evolve: {
    DailyDecisionRecorded: (v) => ({ entries: Count.make(v.entries + 1) }),
    PlanVerdictRecorded: (v) => ({ entries: Count.make(v.entries + 1) }),
    CoachReplied: (v) => ({ entries: Count.make(v.entries + 1) }),
    ProfileRecorded: (v) => ({ entries: Count.make(v.entries + 1) }),
  },
  events: [TimelineEntry],
  emit: {
    DailyDecisionRecorded: (e, { at, source }) =>
      new TimelineEntry({
        at,
        source: { _tag: "DailyDecision", id: source.id },
        entry: { _tag: "Decision", headline: e.note.headline },
      }),
    PlanVerdictRecorded: (e, { at, source }) =>
      new TimelineEntry({
        at,
        source: { _tag: "DailyDecision", id: source.id },
        entry: e.answer._tag === "Accepted" ? { _tag: "Accepted" } : { _tag: "Refused", refusal: e.answer.refusal },
      }),
    CoachReplied: (_, { at, source }) =>
      new TimelineEntry({ at, source: { _tag: "Conversation", id: source.id }, entry: { _tag: "Reply" } }),
    ProfileRecorded: (e, { at, source }) =>
      new TimelineEntry({
        at,
        source: { _tag: "RiderProfile", id: source.id },
        entry: { _tag: "Profile", headline: e.report.headline },
      }),
  },
  validate: Effect.fn(function* (request) {
    yield* mustOwn(request.key);
  }),
}) {}
