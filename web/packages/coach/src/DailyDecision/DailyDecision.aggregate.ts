import { Fingerprint } from "@cadencia/athlete/Evidence";
import { ownerOf } from "@cadencia/identity/Athlete.id";
import { NotYours } from "@cadencia/identity/NotYours.rejection";
import { mustOwn } from "@cadencia/identity/owns";
import * as Domain from "@alchemy.run/domain";
import * as Effect from "effect/Effect";
import * as Schema from "effect/Schema";
import { inputOf } from "../inputOf.ts";
import { Attempt } from "./Attempt.ts";
import { DailyDecisionId, dayOfDecision } from "./DailyDecision.id.ts";
import { DailyDecisionRecorded, DecisionAlreadyAccepted, RecordDailyDecision } from "./RecordDailyDecision.command.ts";
import { PlanVerdictRecorded, RecordPlanVerdict } from "./RecordPlanVerdict.command.ts";

const AttemptState = Schema.Struct({
  attempt: Attempt,
  fingerprint: Fingerprint,
  /** The plan's answer, once it gave one. */
  answer: Schema.NullOr(Schema.Literals(["accepted", "refused"])),
});

const DecisionState = Schema.Struct({
  /** Every attempt the AI made, oldest first. */
  attempts: Schema.Array(AttemptState),
  /** The fingerprint of the attempt the plan holds: the last one it accepted. */
  acceptedFingerprint: Schema.NullOr(Fingerprint),
});

/**
 * The coach's decision for one athlete and one day: every attempt the AI made,
 * with its evidence and model, and what the plan said about each. Attempts
 * aren't serialized (a retry or a second device can add one while another
 * waits), so every answer is kept: the plan may accept an earlier attempt.
 */
export class DailyDecision extends Domain.Aggregate("DailyDecision", {
  id: DailyDecisionId,
  state: DecisionState,
  initial: { attempts: [], acceptedFingerprint: null },
  commands: [RecordDailyDecision, RecordPlanVerdict],
  decide: {
    RecordDailyDecision: Effect.fn(function* (state, cmd, { id }) {
      const athleteId = ownerOf(id);
      yield* mustOwn(athleteId);
      // The decision is for the athlete's own plan; the plan id names its athlete.
      if (ownerOf(cmd.planId) !== athleteId) return yield* new NotYours();
      if (state.acceptedFingerprint === cmd.evidence.fingerprint) {
        return yield* new DecisionAlreadyAccepted({ fingerprint: cmd.evidence.fingerprint });
      }
      return [
        new DailyDecisionRecorded({
          athleteId,
          day: dayOfDecision(id),
          attempt: Attempt.make(state.attempts.length + 1),
          ...inputOf(cmd),
        }),
      ];
    }),
    RecordPlanVerdict: (state, cmd) => {
      const attempt = state.attempts.find((a) => a.attempt === cmd.attempt);
      return !attempt || attempt.answer !== null ? [] : [new PlanVerdictRecorded(inputOf(cmd))];
    },
  },
  evolve: {
    DailyDecisionRecorded: (s, e) => ({
      ...s,
      attempts: [...s.attempts, { attempt: e.attempt, fingerprint: e.evidence.fingerprint, answer: null }],
    }),
    PlanVerdictRecorded: (s, e) => {
      const accepted = e.answer._tag === "Accepted";
      const attempt = s.attempts.find((a) => a.attempt === e.attempt);
      return {
        attempts: s.attempts.map((a) =>
          a.attempt === e.attempt ? { ...a, answer: accepted ? ("accepted" as const) : ("refused" as const) } : a,
        ),
        acceptedFingerprint: accepted && attempt ? attempt.fingerprint : s.acceptedFingerprint,
      };
    },
  },
}) {}
