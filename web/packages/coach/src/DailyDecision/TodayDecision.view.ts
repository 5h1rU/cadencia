import { EvidenceSnapshot } from "@cadencia/athlete/Evidence";
import { AthleteId, ownerOf } from "@cadencia/identity/Athlete.id";
import { NotYours } from "@cadencia/identity/NotYours.rejection";
import { mustOwn } from "@cadencia/identity/owns";
import { Session } from "@cadencia/identity/Session.middleware";
import { Day } from "@cadencia/kernel/Calendar/Day";
import { Workout } from "@cadencia/kernel/Training/Workout";
import * as Domain from "@alchemy.run/domain";
import * as Effect from "effect/Effect";
import * as Schema from "effect/Schema";
import { CoachNote, InterpretedOn, Refusal } from "../CoachShape.ts";
import { ModelName } from "../CoachText.ts";
import { Attempt } from "../Counts.ts";
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
    attempt: Schema.NullOr(Attempt),
    status: Schema.Literals(["none", "pending", "accepted", "refused"]),
    workout: Schema.NullOr(Workout),
    note: Schema.NullOr(CoachNote),
    evidence: Schema.NullOr(EvidenceSnapshot),
    model: Schema.NullOr(ModelName),
    interpretedOn: Schema.NullOr(InterpretedOn),
    refusal: Schema.NullOr(Refusal),
  }),
  initial: {
    athleteId: null,
    day: null,
    attempt: null,
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
        : e.answer._tag === "Accepted"
          ? { ...v, status: "accepted" as const, refusal: null }
          : { ...v, status: "refused" as const, refusal: e.answer.refusal },
  },
  validate: Effect.fn(function* (request) {
    yield* mustOwn(ownerOf(request.key.id));
  }),
}) {}
