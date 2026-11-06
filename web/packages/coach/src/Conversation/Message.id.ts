import { UUID_PATTERN } from "@cadencia/kernel/EntityKey";
import * as Schema from "effect/Schema";

/** One message of a conversation: a lowercase UUID chosen by its author. */
export const MessageId = Schema.String.pipe(
  Schema.check(Schema.isPattern(new RegExp(`^${UUID_PATTERN}$`))),
  Schema.brand("MessageId"),
);
export type MessageId = typeof MessageId.Type;
