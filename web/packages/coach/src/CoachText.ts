import { boundedText } from "@cadencia/kernel/Text";
import * as Schema from "effect/Schema";

/** One line that sums something up: a decision, an intent, a draft. */
export const Headline = boundedText(200).pipe(Schema.brand("Headline"));
export type Headline = typeof Headline.Type;

/** What the athlete or the coach wrote in the conversation. */
export const MessageText = boundedText(8000).pipe(Schema.brand("MessageText"));
export type MessageText = typeof MessageText.Type;

/** The AI model that produced an interpretation, such as `gpt-5.5`. */
export const ModelName = Schema.String.pipe(
  Schema.check(Schema.isPattern(/^[A-Za-z0-9][A-Za-z0-9._:/-]{0,99}$/)),
  Schema.brand("ModelName"),
);
export type ModelName = typeof ModelName.Type;
