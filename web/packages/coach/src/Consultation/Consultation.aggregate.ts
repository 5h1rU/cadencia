import { ownerOf } from "@cadencia/identity/Athlete.id";
import { NotYours } from "@cadencia/identity/NotYours.rejection";
import { mustOwn } from "@cadencia/identity/owns";
import { PlanId } from "@cadencia/kernel/Plan.id";
import * as Domain from "@alchemy.run/domain";
import * as Effect from "effect/Effect";
import * as Schema from "effect/Schema";
import { inputOf } from "../inputOf.ts";
import { AcceptDraft, DraftAccepted, NoDraft } from "./AcceptDraft.command.ts";
import { AnswerQuestion, AthleteAnswered } from "./AnswerQuestion.command.ts";
import { ConsultationId } from "./Consultation.id.ts";
import { ConsultationNotOpen } from "./ConsultationNotOpen.rejection.ts";
import { PlanDraft } from "./PlanDraft.ts";
import { CoachAsked, RecordCoachQuestion } from "./RecordCoachQuestion.command.ts";
import { DraftProposed, RecordDraft } from "./RecordDraft.command.ts";
import { DraftRefusedByPlan, PlanCreatedFromDraft, RecordPlanCreation } from "./RecordPlanCreation.command.ts";
import { ConsultationAlreadyStarted, ConsultationStarted, StartConsultation } from "./StartConsultation.command.ts";

const ConsultationState = Schema.Struct({
  stage: Schema.Literals(["new", "open", "accepted", "created"]),
  draft: Schema.NullOr(PlanDraft),
  planId: Schema.NullOr(PlanId),
});
type ConsultationState = typeof ConsultationState.Type;

const openOnly = Effect.fn(function* (state: ConsultationState, id: ConsultationId) {
  yield* mustOwn(ownerOf(id));
  if (state.stage !== "open") return yield* new ConsultationNotOpen();
});

/** The interview that turns an athlete's goals and availability into a plan draft. */
export class Consultation extends Domain.Aggregate("Consultation", {
  id: ConsultationId,
  state: ConsultationState,
  initial: { stage: "new", draft: null, planId: null },
  commands: [StartConsultation, RecordCoachQuestion, AnswerQuestion, RecordDraft, AcceptDraft, RecordPlanCreation],
  decide: {
    StartConsultation: Effect.fn(function* (state, _cmd, { id }) {
      yield* mustOwn(ownerOf(id));
      if (state.stage !== "new") return yield* new ConsultationAlreadyStarted();
      return [new ConsultationStarted()];
    }),
    RecordCoachQuestion: Effect.fn(function* (state, cmd, { id }) {
      yield* openOnly(state, id);
      return [new CoachAsked(inputOf(cmd))];
    }),
    AnswerQuestion: Effect.fn(function* (state, cmd, { id }) {
      yield* openOnly(state, id);
      return [new AthleteAnswered(inputOf(cmd))];
    }),
    RecordDraft: Effect.fn(function* (state, cmd, { id }) {
      yield* openOnly(state, id);
      return [new DraftProposed(inputOf(cmd))];
    }),
    AcceptDraft: Effect.fn(function* (state, cmd, { id }) {
      yield* openOnly(state, id);
      if (state.draft === null) return yield* new NoDraft();
      // The new plan is the athlete's own; the plan id names its athlete.
      if (ownerOf(cmd.planId) !== ownerOf(id)) return yield* new NotYours();
      return [new DraftAccepted({ planId: cmd.planId, draft: state.draft })];
    }),
    RecordPlanCreation: (state, cmd) =>
      state.stage !== "accepted" || state.planId === null
        ? []
        : cmd.answer._tag === "Accepted"
          ? [new PlanCreatedFromDraft({ planId: state.planId })]
          : [new DraftRefusedByPlan({ refusal: cmd.answer.refusal })],
  },
  evolve: {
    ConsultationStarted: (s) => ({ ...s, stage: "open" as const }),
    CoachAsked: (s) => s,
    AthleteAnswered: (s) => s,
    DraftProposed: (s, e) => ({ ...s, draft: e.draft }),
    DraftAccepted: (s, e) => ({ ...s, stage: "accepted" as const, planId: e.planId }),
    PlanCreatedFromDraft: (s) => ({ ...s, stage: "created" as const }),
    // A refused draft reopens the consultation, so the AI can draft again with the reason.
    DraftRefusedByPlan: (s) => ({ ...s, stage: "open" as const, planId: null }),
  },
}) {}
