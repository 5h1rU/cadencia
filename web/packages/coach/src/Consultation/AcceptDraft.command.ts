import { NotYours } from "@cadencia/identity/NotYours.rejection";
import { Session } from "@cadencia/identity/Session.middleware";
import { PlanId } from "@cadencia/kernel/Plan.id";
import * as Domain from "@alchemy.run/domain";
import { ConsultationId } from "./Consultation.id.ts";
import { ConsultationNotOpen } from "./ConsultationNotOpen.rejection.ts";
import { Count } from "../Count.ts";
import { PlanDraft } from "./PlanDraft.ts";

/** There is no draft to accept yet. */
export class NoDraft extends Domain.Rejection("NoDraft", {}, { httpApiStatus: 409 }) {}

/** The coach drafted again since the athlete read the draft: they must read the new one before accepting it. */
export class DraftChanged extends Domain.Rejection("DraftChanged", { draftRevision: Count }, { httpApiStatus: 409 }) {}

export class DraftAccepted extends Domain.Event("DraftAccepted", { planId: PlanId, draft: PlanDraft }) {}

/**
 * The athlete accepts the draft they read, named by its revision (as the
 * consultation shows it); Planning then creates the plan.
 */
export class AcceptDraft extends Domain.Command("AcceptDraft", {
  target: ConsultationId,
  middleware: [Session],
  input: { planId: PlanId, draftRevision: Count },
  events: [DraftAccepted],
  rejects: [ConsultationNotOpen, NoDraft, DraftChanged, NotYours],
}) {}
