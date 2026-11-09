import { Authenticated } from "@cadencia/identity/Authenticated.middleware";
import { NotYours } from "@cadencia/identity/NotYours.rejection";
import * as Domain from "@alchemy.run/domain";
import { ConsultationId } from "./Consultation.id.ts";

/** The consultation already started. */
export class ConsultationAlreadyStarted extends Domain.Rejection("ConsultationAlreadyStarted", {}, { httpApiStatus: 409 }) {}

export class ConsultationStarted extends Domain.Event("ConsultationStarted", {}) {}

/** Start a consultation to build a plan. */
export class StartConsultation extends Domain.Command("StartConsultation", {
  target: ConsultationId,
  middleware: [Authenticated],
  input: {},
  events: [ConsultationStarted],
  rejects: [ConsultationAlreadyStarted, NotYours],
}) {}
