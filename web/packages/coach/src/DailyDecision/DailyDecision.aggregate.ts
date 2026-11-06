import { AthleteId } from "@cadencia/kernel/Athlete.id";
import { Day } from "@cadencia/kernel/Day";
import { Fingerprint } from "@cadencia/kernel/Evidence";
import { inputOf, mustOwn, ownerOf } from "@cadencia/kernel/owns";
import * as Domain from "@alchemy.run/domain";
import * as Effect from "effect/Effect";
import * as Schema from "effect/Schema";
import { dayOfDecision, DailyDecisionId } from "./DailyDecision.id.ts";
import {
  DailyDecisionRecorded,
  DecisionAlreadyAccepted,
  RecordDailyDecision,
} from "./RecordDailyDecision.command.ts";
import { PlanVerdictRecorded, RecordPlanVerdict } from "./RecordPlanVerdict.command.ts";

const DecisionState = Schema.Struct({
  attempts: Schema.Int,
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
  initial: { attempts: 0, verdict: "none", acceptedFingerprint: null, latestFingerprint: null },
  commands: [RecordDailyDecision, RecordPlanVerdict],
  decide: {
    RecordDailyDecision: Effect.fn(function* (state, cmd, { id }) {
      const athleteId = AthleteId.make(ownerOf(id));
      yield* mustOwn(athleteId);
      if (state.verdict === "accepted" && state.acceptedFingerprint === cmd.evidence.fingerprint) {
        return yield* new DecisionAlreadyAccepted({ fingerprint: cmd.evidence.fingerprint });
      }
      return [
        new DailyDecisionRecorded({
          athleteId,
          day: Day.make(dayOfDecision(id)),
          attempt: state.attempts + 1,
          ...inputOf(cmd),
        }),
      ];
    }),
    RecordPlanVerdict: (state, cmd) =>
      cmd.attempt !== state.attempts || state.verdict !== "pending"
        ? []
        : [new PlanVerdictRecorded(inputOf(cmd))],
  },
  evolve: {
    DailyDecisionRecorded: (s, e) => ({
      ...s,
      attempts: e.attempt,
      verdict: "pending" as const,
      latestFingerprint: e.evidence.fingerprint,
    }),
    PlanVerdictRecorded: (s, e) => ({
      ...s,
      verdict: e.accepted ? ("accepted" as const) : ("refused" as const),
      acceptedFingerprint: e.accepted ? s.latestFingerprint : s.acceptedFingerprint,
    }),
  },
}) {}
