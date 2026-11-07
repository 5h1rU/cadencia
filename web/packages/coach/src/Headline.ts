import { boundedText } from "@cadencia/kernel/Text";
import * as Schema from "effect/Schema";

/** One line that sums something up: a decision, an intent, a draft. */
export const Headline = boundedText(200).pipe(Schema.brand("Headline"));
export type Headline = typeof Headline.Type;
