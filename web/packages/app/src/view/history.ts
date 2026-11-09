import { AsyncData } from "foldkit";
import type { Html, HtmlBuilder } from "foldkit/html";
import { IntervalsProblem, intervalsProblemText } from "../domain/intervalsProblem.ts";
import { Message } from "../message.ts";
import { IntervalsHistory, Model } from "../model.ts";
import { reconnectLink } from "./reconnect.ts";

/** Why the history couldn't be read, with a way to connect again when that's the reason. */
const historyProblem = (h: HtmlBuilder<Message>, problem: IntervalsProblem) =>
  h.p([h.Class("error"), h.AriaLive("polite")], [
    intervalsProblemText(problem),
    ...(problem === "notConnected" ? [" ", reconnectLink(h, "Conectar de nuevo")] : []),
  ]);

/**
 * The cards built from the history, in every state it can be in. Until it is
 * read the page shows `placeholders` shaped like what will come, or one card
 * titled `title`; when it can't be read, that card says why. Data already on
 * screen stays there while it refreshes, dimmed only if the refresh takes a
 * while, and when a refresh fails.
 */
export const historyCards = (
  model: Model,
  h: HtmlBuilder<Message>,
  title: string,
  cards: (history: IntervalsHistory) => ReadonlyArray<Html>,
  placeholders?: (reading: Html) => ReadonlyArray<Html>,
): ReadonlyArray<Html> => {
  const alone = (content: Html) => [h.div([h.Class("card")], [h.h2([], [title]), content])];
  const reading = h.p([h.Class("muted"), h.AriaLive("polite")], ["Leyendo Intervals.icu…"]);
  const loading = () => (placeholders ? placeholders(reading) : alone(reading));
  return AsyncData.match(model.history, {
    onIdle: loading,
    onLoading: loading,
    onFailure: (problem) => alone(historyProblem(h, problem)),
    onRefreshing: (history) => [h.p([h.Class("pending"), h.AriaLive("polite")], ["Actualizando desde Intervals.icu…"]), ...cards(history)],
    onStale: ({ error, data }) => [historyProblem(h, error), ...cards(data)],
    onSuccess: cards,
  });
};
