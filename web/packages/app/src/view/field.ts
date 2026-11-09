import * as Array from "effect/Array";
import * as Option from "effect/Option";
import { FieldValidation } from "foldkit";
import type { Attribute, Html, HtmlBuilder } from "foldkit/html";
import { TextField } from "../domain/form.ts";
import { Message } from "../message.ts";

/** The message under a field that fails its rules. */
const errorOf = (field: TextField): Option.Option<string> =>
  FieldValidation.match(field, {
    onNotValidated: () => Option.none(),
    onValidating: () => Option.none(),
    onValid: () => Option.none(),
    onInvalid: ({ errors }) => Option.some(Array.headNonEmpty(errors)),
  });

/**
 * A labelled form control and, when its field fails its rules, the reason
 * under it: the control is marked invalid and described by that reason.
 */
export const fieldView = (
  h: HtmlBuilder<Message>,
  id: string,
  label: string,
  field: TextField,
  control: (attributes: ReadonlyArray<Attribute<Message>>) => Html,
) => {
  const error = errorOf(field);
  const errorId = `${id}-error`;
  return h.label([], [
    label,
    control([
      h.Id(id),
      h.Value(field.value),
      h.AriaInvalid(Option.isSome(error)),
      ...Array.fromOption(Option.as(error, h.AriaDescribedBy(errorId))),
    ]),
    ...Array.fromOption(Option.map(error, (reason) => h.span([h.Id(errorId), h.Class("error")], [reason]))),
  ]);
};
