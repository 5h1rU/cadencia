import { AthleteId } from "@cadencia/identity/Athlete.id";
import { NotYours } from "@cadencia/identity/NotYours.rejection";
import { Session } from "@cadencia/identity/Session.middleware";
import * as Domain from "@alchemy.run/domain";
import * as Schema from "effect/Schema";

/** An automatic generation already ran once; only an explicit request may spend another. */
export class AutomaticAttemptUsed extends Domain.Rejection("AutomaticAttemptUsed", {}, { httpApiStatus: 409 }) {}

export class ProfileAttempted extends Domain.Event("ProfileAttempted", { automatic: Schema.Boolean }) {}

/**
 * Record that a device is about to ask the AI for a profile, before any network
 * work, so no device spends a second automatic generation.
 */
export class RecordProfileAttempt extends Domain.Command("RecordProfileAttempt", {
  target: AthleteId,
  middleware: [Session],
  input: { automatic: Schema.Boolean },
  events: [ProfileAttempted],
  rejects: [AutomaticAttemptUsed, NotYours],
}) {}
