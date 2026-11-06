import { AthleteId } from "@cadencia/kernel/Athlete.id";
import { Day } from "@cadencia/kernel/Day";
import { EvidenceSnapshot } from "@cadencia/kernel/Evidence";
import { NotYours } from "@cadencia/kernel/NotYours.rejection";
import { mustOwn, ownerOf } from "@cadencia/kernel/owns";
import { Session } from "@cadencia/kernel/Session.middleware";
import { Workout } from "@cadencia/kernel/Workout";
import * as Domain from "@alchemy.run/domain";
import * as Effect from "effect/Effect";
import * as Schema from "effect/Schema";
import { CoachNote, InterpretedOn } from "../CoachShape.ts";
import { DailyDecision } from "./DailyDecision.aggregate.ts";

/** The day's decision as the athlete sees it: the latest proposal and the plan's answer. */
export class TodayDecision extends Domain.View("TodayDecision", {
  from: [DailyDecision],
  key: DailyDecision,
  middleware: [Session],
  rejects: [NotYours],
  state: Schema.Struct({
    athleteId: Schema.NullOr(AthleteId),
    day: Schema.NullOr(Day),
    attempt: Schema.Int,
    status: Schema.Literals(["none", "pending", "accepted", "refused"]),
    workout: Schema.NullOr(Workout),
    note: Schema.NullOr(CoachNote),
    evidence: Schema.NullOr(EvidenceSnapshot),
    model: Schema.NullOr(Schema.String),
    interpretedOn: Schema.NullOr(InterpretedOn),
    refusal: Schema.NullOr(Schema.String),
  }),
  initial: {
    athleteId: null,
    day: null,
    attempt: 0,
    status: "none",
    workout: null,
    note: null,
    evidence: null,
    model: null,
    interpretedOn: null,
    refusal: null,
  },
  evolve: {
    DailyDecisionRecorded: (_, e) => ({
      athleteId: e.athleteId,
      day: e.day,
      attempt: e.attempt,
      status: "pending" as const,
      workout: e.workout,
      note: e.note,
      evidence: e.evidence,
      model: e.model,
      interpretedOn: e.interpretedOn,
      refusal: null,
    }),
    PlanVerdictRecorded: (v, e) =>
      e.attempt !== v.attempt
        ? v
        : { ...v, status: e.accepted ? ("accepted" as const) : ("refused" as const), refusal: e.reason },
  },
  validate: Effect.fn(function* (request) {
    yield* mustOwn(AthleteId.make(ownerOf(request.key.id)));
  }),
}) {}
