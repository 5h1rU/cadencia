import { AthleteId } from "@cadencia/kernel/Athlete.id";
import { NotYours } from "@cadencia/kernel/NotYours.rejection";
import { mustOwn, ownerOf } from "@cadencia/kernel/owns";
import { Session } from "@cadencia/kernel/Session.middleware";
import * as Domain from "@alchemy.run/domain";
import * as Effect from "effect/Effect";
import * as Schema from "effect/Schema";
import { Consultation } from "./Consultation.aggregate.ts";
import { PlanDraft } from "./PlanDraft.ts";

const Turn = Schema.Struct({ role: Schema.Literals(["coach", "athlete"]), text: Schema.String });

/** A consultation as the athlete follows it: the questions, the answers and the draft. */
export class ConsultationView extends Domain.View("ConsultationView", {
  from: [Consultation],
  key: Consultation,
  middleware: [Session],
  rejects: [NotYours],
  state: Schema.Struct({
    stage: Schema.Literals(["new", "open", "accepted", "created", "refused"]),
    turns: Schema.Array(Turn),
    draft: Schema.NullOr(PlanDraft),
    planId: Schema.NullOr(Schema.String),
    refusal: Schema.NullOr(Schema.String),
  }),
  initial: { stage: "new", turns: [], draft: null, planId: null, refusal: null },
  evolve: {
    ConsultationStarted: (v) => ({ ...v, stage: "open" as const }),
    CoachAsked: (v, e) => ({ ...v, turns: [...v.turns, { role: "coach" as const, text: e.text }] }),
    AthleteAnswered: (v, e) => ({ ...v, turns: [...v.turns, { role: "athlete" as const, text: e.text }] }),
    DraftProposed: (v, e) => ({ ...v, draft: e.draft, refusal: null }),
    DraftAccepted: (v, e) => ({ ...v, stage: "accepted" as const, planId: e.planId }),
    PlanCreatedFromDraft: (v) => ({ ...v, stage: "created" as const }),
    DraftRefusedByPlan: (v, e) => ({ ...v, stage: "open" as const, planId: null, refusal: e.reason }),
  },
  validate: Effect.fn(function* (request) {
    yield* mustOwn(AthleteId.make(ownerOf(request.key.id)));
  }),
}) {}
