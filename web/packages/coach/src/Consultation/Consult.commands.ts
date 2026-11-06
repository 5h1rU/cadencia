import { NotYours } from "@cadencia/kernel/NotYours.rejection";
import { Session } from "@cadencia/kernel/Session.middleware";
import * as Domain from "@alchemy.run/domain";
import * as Schema from "effect/Schema";
import { InterpretedOn } from "../CoachShape.ts";
import { ConsultationId } from "./Consultation.id.ts";
import { ConsultationNotOpen } from "./ConsultationNotOpen.rejection.ts";
import { PlanDraft } from "./PlanDraft.ts";

/** The consultation already started. */
export class ConsultationAlreadyStarted extends Domain.Rejection("ConsultationAlreadyStarted", {}, { httpApiStatus: 409 }) {}

/** There is no draft to accept yet. */
export class NoDraft extends Domain.Rejection("NoDraft", {}, { httpApiStatus: 409 }) {}

export class ConsultationStarted extends Domain.Event("ConsultationStarted", {}) {}
export class CoachAsked extends Domain.Event("CoachAsked", {
  text: Schema.String,
  model: Schema.String,
  interpretedOn: InterpretedOn,
}) {}
export class AthleteAnswered extends Domain.Event("AthleteAnswered", { text: Schema.String }) {}
export class DraftProposed extends Domain.Event("DraftProposed", {
  draft: PlanDraft,
  model: Schema.String,
  interpretedOn: InterpretedOn,
}) {}
export class DraftAccepted extends Domain.Event("DraftAccepted", { planId: Schema.String, draft: PlanDraft }) {}
export class PlanCreatedFromDraft extends Domain.Event("PlanCreatedFromDraft", { planId: Schema.String }) {}
export class DraftRefusedByPlan extends Domain.Event("DraftRefusedByPlan", { reason: Schema.String }) {}

/** Start a consultation to build a plan. */
export class StartConsultation extends Domain.Command("StartConsultation", {
  target: ConsultationId,
  middleware: [Session],
  input: {},
  events: [ConsultationStarted],
  rejects: [ConsultationAlreadyStarted, NotYours],
}) {}

/** Record the AI's next question. */
export class RecordCoachQuestion extends Domain.Command("RecordCoachQuestion", {
  target: ConsultationId,
  middleware: [Session],
  input: { text: Schema.String, model: Schema.String, interpretedOn: InterpretedOn },
  events: [CoachAsked],
  rejects: [ConsultationNotOpen, NotYours],
}) {}

/** The athlete answers. */
export class AnswerQuestion extends Domain.Command("AnswerQuestion", {
  target: ConsultationId,
  middleware: [Session],
  input: { text: Schema.String },
  events: [AthleteAnswered],
  rejects: [ConsultationNotOpen, NotYours],
}) {}

/** Record the plan the AI drafted from the answers. */
export class RecordDraft extends Domain.Command("RecordDraft", {
  target: ConsultationId,
  middleware: [Session],
  input: { draft: PlanDraft, model: Schema.String, interpretedOn: InterpretedOn },
  events: [DraftProposed],
  rejects: [ConsultationNotOpen, NotYours],
}) {}

/** The athlete accepts the draft; Planning then creates the plan. */
export class AcceptDraft extends Domain.Command("AcceptDraft", {
  target: ConsultationId,
  middleware: [Session],
  input: { planId: Schema.String },
  events: [DraftAccepted],
  rejects: [ConsultationNotOpen, NoDraft, NotYours],
}) {}

/** Record what Planning did with the accepted draft. Sent by `PlanFromConsultation`; it never rejects. */
export class RecordPlanCreation extends Domain.Command("RecordPlanCreation", {
  target: ConsultationId,
  input: { accepted: Schema.Boolean, reason: Schema.NullOr(Schema.String) },
  events: [PlanCreatedFromDraft, DraftRefusedByPlan],
}) {}
