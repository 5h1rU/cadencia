import { ATHLETE_ID_PATTERN } from "@cadencia/identity/Athlete.id";
import { UUID_PATTERN } from "@cadencia/kernel/EntityKey";
import type { PlanId } from "@cadencia/kernel/Plan.id";
import * as Schema from "effect/Schema";

/** A session of a plan. A plan has at most one session per day, so the day names it. */
export const SessionId = Schema.String.pipe(
  Schema.check(Schema.isPattern(/^\d{4}-\d{2}-\d{2}$/)),
  Schema.brand("SessionId"),
);
export type SessionId = typeof SessionId.Type;

/** The `external_id` Cadencia gives a session in the Intervals.icu calendar. */
export const ExternalId = Schema.String.pipe(
  Schema.check(Schema.isPattern(new RegExp(`^cadencia-${ATHLETE_ID_PATTERN}-${UUID_PATTERN}-\\d{4}-\\d{2}-\\d{2}$`))),
  Schema.brand("ExternalId"),
);
export type ExternalId = typeof ExternalId.Type;

/** The `external_id` of a plan session in Intervals.icu. */
export const externalIdFor = (planId: PlanId, sessionId: SessionId): ExternalId =>
  ExternalId.make(`cadencia-${planId.replace(":", "-")}-${sessionId}`);

/** The event a session became in the Intervals.icu calendar. */
export const IntervalsEventId = Schema.Int.pipe(Schema.check(Schema.isGreaterThanOrEqualTo(1)), Schema.brand("IntervalsEventId"));
export type IntervalsEventId = typeof IntervalsEventId.Type;
