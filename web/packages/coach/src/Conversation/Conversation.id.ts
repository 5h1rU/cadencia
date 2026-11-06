import * as Schema from "effect/Schema";

/** One month of an athlete's conversation with the coach: `<athleteId>:<YYYY-MM>`. */
export const ConversationId = Schema.String.pipe(
  Schema.check(Schema.isPattern(/^[^:]+:\d{4}-\d{2}$/)),
  Schema.brand("ConversationId"),
);
export type ConversationId = typeof ConversationId.Type;
