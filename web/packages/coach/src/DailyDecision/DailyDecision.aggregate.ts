import { Fingerprint } from "@cadencia/athlete/Evidence";
import { ownerOf } from "@cadencia/identity/Athlete.id";
import { mustOwn } from "@cadencia/identity/owns";
import * as Domain from "@alchemy.run/domain";
import * as Effect from "effect/Effect";
import * as Schema from "effect/Schema";
import { Attempt } from "../Counts.ts";
import { inputOf } from "../inputOf.ts";
import { DailyDecisionId, dayOfDecision } from "./DailyDecision.id.ts";
import { DailyDecisionRecorded, DecisionAlreadyAccepted, RecordDailyDecision } from "./RecordDailyDecision.command.ts";
import { PlanVerdictRecorded, RecordPlanVerdict } from "./RecordPlanVerdict.command.ts";

const DecisionState = Schema.Struct({
  /** The latest attempt, if the AI made one. */
  latestAttempt: Schema.NullOr(Attempt),
  verdict: Schema.Literals(["none", "pending", "accepted", "refused"]),
  /** The fingerprint of the attempt the plan accepted, if any. */
  acceptedFingerprint: Schema.NullOr(Fingerprint),
  /** The fingerprint of the latest attempt. */
  latestFingerprint: Schema.NullOr(Fingerprint),
});

/**
 * The coach's decision for one athlete and one day: every attempt the AI made,
 * with its evidence and model, and what the plan said about it.
 */
export class DailyDecision extends Domain.Aggregate("DailyDecision", {
  id: DailyDecisionId,
  state: DecisionState,
  initial: { latestAttempt: null, verdict: "none", acceptedFingerprint: null, latestFingerprint: null },
  commands: [RecordDailyDecision, RecordPlanVerdict],
  decide: {
    RecordDailyDecision: Effect.fn(function* (state, cmd, { id }) {
      const athleteId = ownerOf(id);
      yield* mustOwn(athleteId);
      if (state.verdict === "accepted" && state.acceptedFingerprint === cmd.evidence.fingerprint) {
        return yield* new DecisionAlreadyAccepted({ fingerprint: cmd.evidence.fingerprint });
      }
      return [
        new DailyDecisionRecorded({
          athleteId,
          day: dayOfDecision(id),
          attempt: Attempt.make((state.latestAttempt ?? 0) + 1),
          ...inputOf(cmd),
        }),
      ];
    }),
    RecordPlanVerdict: (state, cmd) =>
      cmd.attempt !== state.latestAttempt || state.verdict !== "pending" ? [] : [new PlanVerdictRecorded(inputOf(cmd))],
  },
  evolve: {
    DailyDecisionRecorded: (s, e) => ({
      ...s,
      latestAttempt: e.attempt,
      verdict: "pending" as const,
      latestFingerprint: e.evidence.fingerprint,
    }),
    PlanVerdictRecorded: (s, e) => ({
      ...s,
      verdict: e.answer._tag === "Accepted" ? ("accepted" as const) : ("refused" as const),
      acceptedFingerprint: e.answer._tag === "Accepted" ? s.latestFingerprint : s.acceptedFingerprint,
    }),
  },
}) {}
