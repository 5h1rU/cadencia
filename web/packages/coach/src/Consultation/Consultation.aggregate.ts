import { AthleteId } from "@cadencia/kernel/Athlete.id";
import { inputOf, mustOwn, ownerOf } from "@cadencia/kernel/owns";
import * as Domain from "@alchemy.run/domain";
import * as Effect from "effect/Effect";
import * as Schema from "effect/Schema";
import {
  AcceptDraft,
  AnswerQuestion,
  AthleteAnswered,
  CoachAsked,
  ConsultationAlreadyStarted,
  ConsultationStarted,
  DraftAccepted,
  DraftProposed,
  DraftRefusedByPlan,
  NoDraft,
  PlanCreatedFromDraft,
  RecordCoachQuestion,
  RecordDraft,
  RecordPlanCreation,
  StartConsultation,
} from "./Consult.commands.ts";
import { ConsultationId } from "./Consultation.id.ts";
import { ConsultationNotOpen } from "./ConsultationNotOpen.rejection.ts";
import { PlanDraft } from "./PlanDraft.ts";

const ConsultationState = Schema.Struct({
  stage: Schema.Literals(["new", "open", "accepted", "created", "refused"]),
  draft: Schema.NullOr(PlanDraft),
  planId: Schema.NullOr(Schema.String),
});
type ConsultationState = typeof ConsultationState.Type;

const owner = (id: string) => mustOwn(AthleteId.make(ownerOf(id)));

const openOnly = Effect.fn(function* (state: ConsultationState, id: string) {
  yield* owner(id);
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
      yield* owner(id);
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
      return [new DraftAccepted({ planId: cmd.planId, draft: state.draft })];
    }),
    RecordPlanCreation: (state, cmd) =>
      state.stage !== "accepted"
        ? []
        : cmd.accepted
          ? [new PlanCreatedFromDraft({ planId: state.planId ?? "" })]
          : [new DraftRefusedByPlan({ reason: cmd.reason ?? "Refused by the plan" })],
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
