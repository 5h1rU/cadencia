import { Day } from "@cadencia/kernel/Calendar/Day";
import { Paragraph, Title } from "@cadencia/kernel/Text";
import { SessionKind } from "@cadencia/kernel/Training/SessionKind";
import { Minutes } from "@cadencia/kernel/Training/Units";
import * as Schema from "effect/Schema";

/** What a new plan's sessions look like before they have ids. */
export const SessionDraft = Schema.Struct({
  day: Day,
  kind: SessionKind,
  title: Title,
  targetMinutes: Minutes,
  purpose: Paragraph,
});
export type SessionDraft = typeof SessionDraft.Type;
