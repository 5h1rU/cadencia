import { ATHLETE_ID_PATTERN, type AthleteId } from "@cadencia/identity/Athlete.id";
import type { Day } from "@cadencia/kernel/Calendar/Day";
import * as Schema from "effect/Schema";

const MONTH_PATTERN = "\\d{4}-(0[1-9]|1[0-2])";

/** A month, as `YYYY-MM`: a conversation keeps one month of messages. */
export const YearMonth = Schema.String.pipe(
  Schema.check(Schema.isPattern(new RegExp(`^${MONTH_PATTERN}$`))),
  Schema.brand("YearMonth"),
);
export type YearMonth = typeof YearMonth.Type;

/** The month a day falls in. */
export const monthOf = (day: Day): YearMonth => YearMonth.make(day.slice(0, 7));

/** One month of an athlete's conversation with the coach: `<athleteId>:<YYYY-MM>`. */
export const ConversationId = Schema.String.pipe(
  Schema.check(Schema.isPattern(new RegExp(`^${ATHLETE_ID_PATTERN}:${MONTH_PATTERN}$`))),
  Schema.brand("ConversationId"),
);
export type ConversationId = typeof ConversationId.Type;

export const conversationIdFor = (athleteId: AthleteId, month: YearMonth): ConversationId =>
  ConversationId.make(`${athleteId}:${month}`);
