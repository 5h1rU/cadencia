import { ownerOf } from "@cadencia/identity/Athlete.id";
import { NotYours } from "@cadencia/identity/NotYours.rejection";
import { mustOwn } from "@cadencia/identity/owns";
import { Session } from "@cadencia/identity/Session.middleware";
import { PlanId } from "@cadencia/kernel/Plan.id";
import * as Domain from "@alchemy.run/domain";
import * as Effect from "effect/Effect";
import * as Schema from "effect/Schema";
import { Refusal } from "../CoachShape.ts";
import { MessageText } from "../CoachText.ts";
import { Consultation } from "./Consultation.aggregate.ts";
import { PlanDraft } from "./PlanDraft.ts";

const Turn = Schema.Struct({ role: Schema.Literals(["coach", "athlete"]), text: MessageText });

/** A consultation as the athlete follows it: the questions, the answers and the draft. */
export class ConsultationView extends Domain.View("ConsultationView", {
  from: [Consultation],
  key: Consultation,
  middleware: [Session],
  rejects: [NotYours],
  state: Schema.Struct({
    stage: Schema.Literals(["new", "open", "accepted", "created"]),
    turns: Schema.Array(Turn),
    draft: Schema.NullOr(PlanDraft),
    planId: Schema.NullOr(PlanId),
    refusal: Schema.NullOr(Refusal),
  }),
  initial: { stage: "new", turns: [], draft: null, planId: null, refusal: null },
  evolve: {
    ConsultationStarted: (v) => ({ ...v, stage: "open" as const }),
    CoachAsked: (v, e) => ({ ...v, turns: [...v.turns, { role: "coach" as const, text: e.text }] }),
    AthleteAnswered: (v, e) => ({ ...v, turns: [...v.turns, { role: "athlete" as const, text: e.text }] }),
    DraftProposed: (v, e) => ({ ...v, draft: e.draft, refusal: null }),
    DraftAccepted: (v, e) => ({ ...v, stage: "accepted" as const, planId: e.planId }),
    PlanCreatedFromDraft: (v) => ({ ...v, stage: "created" as const }),
    DraftRefusedByPlan: (v, e) => ({ ...v, stage: "open" as const, planId: null, refusal: e.refusal }),
  },
  validate: Effect.fn(function* (request) {
    yield* mustOwn(ownerOf(request.key.id));
  }),
}) {}
