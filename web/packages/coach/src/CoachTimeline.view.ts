import { AthleteId } from "@cadencia/kernel/Athlete.id";
import { NotYours } from "@cadencia/kernel/NotYours.rejection";
import { mustOwn, ownerOf } from "@cadencia/kernel/owns";
import { Session } from "@cadencia/kernel/Session.middleware";
import * as Domain from "@alchemy.run/domain";
import * as DateTime from "effect/DateTime";
import * as Effect from "effect/Effect";
import * as Schema from "effect/Schema";
import { Conversation } from "./Conversation/Conversation.aggregate.ts";
import { DailyDecision } from "./DailyDecision/DailyDecision.aggregate.ts";
import { RiderProfile } from "./RiderProfile/RiderProfile.aggregate.ts";

/** One thing the coach did, for the athlete's history. */
export class TimelineEntry extends Domain.Event("TimelineEntry", {
  kind: Schema.Literals(["decision", "verdict", "reply", "profile"]),
  at: Schema.String,
  headline: Schema.String,
  /** The aggregate it came from, to open the detail. */
  sourceId: Schema.String,
}) {}

/** Everything the coach did for an athlete, newest last. Page through it with `list`. */
export class CoachTimeline extends Domain.View("CoachTimeline", {
  from: [DailyDecision, Conversation, RiderProfile],
  key: AthleteId,
  middleware: [Session],
  rejects: [NotYours],
  keyOf: {
    DailyDecision: ({ source }) => AthleteId.make(ownerOf(source.id)),
    Conversation: ({ source }) => AthleteId.make(ownerOf(source.id)),
    RiderProfile: ({ source }) => AthleteId.make(source.id),
  },
  state: Schema.Struct({ entries: Schema.Int }),
  initial: { entries: 0 },
  evolve: {
    DailyDecisionRecorded: (v) => ({ entries: v.entries + 1 }),
    PlanVerdictRecorded: (v) => ({ entries: v.entries + 1 }),
    CoachReplied: (v) => ({ entries: v.entries + 1 }),
    ProfileRecorded: (v) => ({ entries: v.entries + 1 }),
  },
  events: [TimelineEntry],
  emit: {
    DailyDecisionRecorded: (e, { at, source }) =>
      new TimelineEntry({ kind: "decision", at: DateTime.formatIso(at), headline: e.note.headline, sourceId: source.id }),
    PlanVerdictRecorded: (e, { at, source }) =>
      new TimelineEntry({
        kind: "verdict",
        at: DateTime.formatIso(at),
        headline: e.accepted ? "Plan accepted the session" : `Plan refused: ${e.reason ?? "no reason"}`,
        sourceId: source.id,
      }),
    CoachReplied: (e, { at, source }) =>
      new TimelineEntry({ kind: "reply", at: DateTime.formatIso(at), headline: e.text.slice(0, 120), sourceId: source.id }),
    ProfileRecorded: (e, { at, source }) =>
      new TimelineEntry({ kind: "profile", at: DateTime.formatIso(at), headline: e.report.headline, sourceId: source.id }),
  },
  validate: Effect.fn(function* (request) {
    yield* mustOwn(request.key);
  }),
}) {}
