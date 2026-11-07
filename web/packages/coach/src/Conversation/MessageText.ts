import { boundedText } from "@cadencia/kernel/Text";
import * as Schema from "effect/Schema";

/** What the athlete or the coach wrote in the conversation. */
export const MessageText = boundedText(8000).pipe(Schema.brand("MessageText"));
export type MessageText = typeof MessageText.Type;
