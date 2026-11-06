import * as Schema from "effect/Schema";

/**
 * Text with no leading or trailing whitespace, not blank, and at most `max`
 * characters. Brand it where it is used: `boundedText(120).pipe(Schema.brand("Title"))`.
 */
export const boundedText = (max: number) =>
  Schema.String.pipe(Schema.check(Schema.isTrimmed(), Schema.isNonEmpty(), Schema.isMaxLength(max)));

/** A short name: a plan, a session, a workout or one of its blocks, an event. */
export const Title = boundedText(120).pipe(Schema.brand("Title"));
export type Title = typeof Title.Type;

/** A paragraph of explanation. */
export const Paragraph = boundedText(4000).pipe(Schema.brand("Paragraph"));
export type Paragraph = typeof Paragraph.Type;
