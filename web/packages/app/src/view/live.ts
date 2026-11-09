import { AsyncData } from "foldkit";
import type { Html, HtmlBuilder } from "foldkit/html";
import { notYours } from "../domain/rejection.ts";
import { Message } from "../message.ts";
import { ReadProblem } from "../model.ts";

/**
 * What a live view shows in each of its states: until its first snapshot comes,
 * or when it is refused, a line says so where its content would be.
 */
export const liveContent = <A>(
  h: HtmlBuilder<Message>,
  view: AsyncData.AsyncData<A, typeof ReadProblem.Type>,
  content: (data: A) => ReadonlyArray<Html>,
): ReadonlyArray<Html> =>
  AsyncData.matchData(view, {
    onEmpty: () => [h.p([h.Class("muted"), h.AriaLive("polite")], ["Cargando…"])],
    onFailure: () => [h.p([h.Class("error")], [notYours()])],
    onData: content,
  });
