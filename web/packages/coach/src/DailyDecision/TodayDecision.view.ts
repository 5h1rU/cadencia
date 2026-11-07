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
import { CoachNote } from "../CoachNote.ts";
import { InterpretedOn, ModelName } from "../Provenance.ts";
import { Refusal } from "../Refusal.ts";
import { Attempt } from "./Attempt.ts";
import { DailyDecision } from "./DailyDecision.aggregate.ts";

const Proposal = Schema.Struct({ attempt: Attempt, workout: Workout, note: CoachNote });

/**
 * The day's decision as the athlete sees it: the latest proposal, the plan's
 * answer to it, and the proposal the plan holds, which can be an earlier one.
 */
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
    /** The proposal the plan accepted last, if any. */
    planHolds: Schema.NullOr(Proposal),
    /** Proposals still waiting for the plan's answer. */
    awaiting: Schema.Array(Proposal),
  }),
  // Bump when the state or how it folds changes, so the view is rebuilt from the decision's events.
  version: 1,
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
    planHolds: null,
    awaiting: [],
  },
  evolve: {
    DailyDecisionRecorded: (v, e) => ({
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
      planHolds: v.planHolds,
      awaiting: [...v.awaiting, { attempt: e.attempt, workout: e.workout, note: e.note }],
    }),
    PlanVerdictRecorded: (v, e) => {
      const proposal = v.awaiting.find((p) => p.attempt === e.attempt);
      const answered = {
        ...v,
        awaiting: v.awaiting.filter((p) => p.attempt !== e.attempt),
        planHolds: e.answer._tag === "Accepted" && proposal ? proposal : v.planHolds,
      };
      if (e.attempt !== v.attempt) return answered;
      return e.answer._tag === "Accepted"
        ? { ...answered, status: "accepted" as const, refusal: null }
        : { ...answered, status: "refused" as const, refusal: e.answer.refusal };
    },
  },
  validate: Effect.fn(function* (request) {
    yield* mustOwn(ownerOf(request.key.id));
  }),
}) {}
