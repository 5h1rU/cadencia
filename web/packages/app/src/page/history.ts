import * as Array from "effect/Array";
import type { Html, HtmlBuilder } from "foldkit/html";
import { Message } from "../message.ts";
import { Model } from "../model.ts";
import { historyCards } from "../view/history.ts";

/** A grey bar where a line of the history will be. */
const placeholderLine = (h: HtmlBuilder<Message>) => h.div([h.Class("placeholder"), h.AriaHidden(true)], []);

const ACTIVITIES_TITLE = "Actividades de las últimas cuatro semanas";

/** The history page's cards, while Intervals.icu is read: the same cards, with grey lines for what they will hold. */
const historyPlaceholders = (h: HtmlBuilder<Message>) => (reading: Html) => [
  h.div([h.Class("card history-form")], [h.h2([], ["Forma"]), placeholderLine(h)]),
  h.div([h.Class("card history-activities")], [h.h2([], [ACTIVITIES_TITLE]), reading, ...Array.makeBy(5, () => placeholderLine(h))]),
];

export const view = (model: Model, h: HtmlBuilder<Message>) =>
  historyCards(model, h, "Forma", ({ wellness, activities }) => {
  const latest = wellness.at(-1);
  return [
    h.div([h.Class("card history-form")], [
      h.h2([], ["Forma"]),
      latest && latest.fitness !== null && latest.acuteLoad !== null
        ? h.p([], [
            `Forma (CTL) ${latest.fitness.toFixed(0)} · Fatiga (ATL) ${latest.acuteLoad.toFixed(0)} · Balance ${(latest.fitness - latest.acuteLoad).toFixed(0)}`,
          ])
        : h.p([h.Class("muted")], ["Sin datos de bienestar en las últimas cuatro semanas."]),
    ]),
    h.div([h.Class("card history-activities")], [
      h.h2([], [ACTIVITIES_TITLE]),
      activities.length === 0
        ? h.p([h.Class("muted")], ["No hay actividades en Intervals.icu en estas fechas."])
        : h.div([h.Class("scroll")], [
            h.table([], [
              h.thead([], [
                h.tr([], [h.th([], ["Fecha"]), h.th([], ["Actividad"]), h.th([], ["Min"]), h.th([], ["Carga"]), h.th([], ["NP"])]),
              ]),
              h.tbody(
                [],
                [...activities].reverse().map((a) =>
                  h.keyed("tr")(a.activityId, [h.Class("activity")], [
                    h.td([], [a.day ?? ""]),
                    h.td([], [a.name ?? ""]),
                    h.td([], [a.movingTime !== null ? String(Math.round(a.movingTime / 60)) : ""]),
                    h.td([], [a.trainingLoad !== null ? a.trainingLoad.toFixed(0) : ""]),
                    h.td([], [a.normalizedPower !== null ? `${a.normalizedPower.toFixed(0)} W` : ""]),
                  ]),
                ),
              ),
            ]),
          ]),
    ]),
  ];
  }, historyPlaceholders(h));
