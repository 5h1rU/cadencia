import { NotYours } from "@cadencia/identity/NotYours.rejection";
import { Session } from "@cadencia/identity/Session.middleware";
import * as Domain from "@alchemy.run/domain";
import { ConsultationId } from "./Consultation.id.ts";

/** The consultation already started. */
export class ConsultationAlreadyStarted extends Domain.Rejection("ConsultationAlreadyStarted", {}, { httpApiStatus: 409 }) {}

export class ConsultationStarted extends Domain.Event("ConsultationStarted", {}) {}

/** Start a consultation to build a plan. */
export class StartConsultation extends Domain.Command("StartConsultation", {
  target: ConsultationId,
  middleware: [Session],
  input: {},
  events: [ConsultationStarted],
  rejects: [ConsultationAlreadyStarted, NotYours],
}) {}
