import * as Option from "effect/Option";
import { AsyncData } from "foldkit";
import type { Document, HtmlBuilder } from "foldkit/html";
import { Message } from "./message.ts";
import { historyOnScreen, Model } from "./model.ts";
import * as Coach from "./page/coach.ts";
import * as History from "./page/history.ts";
import * as Home from "./page/home.ts";
import * as NotFound from "./page/notFound.ts";
import * as Plan from "./page/plan.ts";
import * as Profile from "./page/profile.ts";
import { AppRoute, coachRouter, historyRouter, homeRouter, planRouter, profileRouter } from "./route.ts";
import { reconnectLink } from "./view/reconnect.ts";

/** The pages in the navigation: where each lives and what it is called. */
export const PAGES: ReadonlyArray<readonly [AppRoute["_tag"], string, string]> = [
  ["Home", homeRouter(), "Hoy"],
  ["Coach", coachRouter(), "Coach"],
  ["Plan", planRouter(), "Plan"],
  ["History", historyRouter(), "Historial"],
  ["Profile", profileRouter(), "Perfil"],
];

/** The write in flight, or the one whose outcome is unknown, with what can be done about it. */
const writeStatus = (model: Model, h: HtmlBuilder<Message>) =>
  Option.match(model.inFlight, {
    onNone: () => [],
    onSome: (inFlight) =>
      inFlight.outcome === "sending"
        ? [h.p([h.Class("muted"), h.AriaLive("polite")], ["Guardando…"])]
        : [
            h.div([h.Class("row"), h.AriaLive("polite")], [
              h.button([h.Class("primary"), h.OnClick(Message.ClickedRetryWrite())], ["Reintentar"]),
              h.button([h.Class("secondary"), h.OnClick(Message.ClickedForgetWrite())], ["Dejarlo"]),
            ]),
          ],
  });

export const view = (model: Model, h: HtmlBuilder<Message>): Document => ({
  title: "Cadencia",
  body: h.div([h.Class("app")], [
    h.header([h.Class("top")], [
      h.h1([], ["Cadencia"]),
      ...(model.athleteId === null
        ? []
        : [
            h.nav(
              [h.Class("sections"), h.AriaLabel("Secciones")],
              PAGES.map(([tag, href, label]) =>
                h.a([h.Href(href), ...(model.route._tag === tag ? [h.AriaCurrent("page")] : [])], [label]),
              ),
            ),
          ]),
    ]),
    ...(model.unreachable
      ? [
          h.div([h.Class("card")], [
            h.h2([], ["No se pudo conectar con Cadencia"]),
            h.p([], ["Comprueba tu conexión y vuelve a intentarlo."]),
            h.button([h.Class("primary"), h.OnClick(Message.ClickedRetryStart())], ["Reintentar"]),
          ]),
        ]
      : model.athleteId === null
      ? [
          h.div([h.Class("card")], [
            h.h2([], ["Entra con tu cuenta de Intervals.icu"]),
            ...Option.match(model.error, { onNone: () => [], onSome: (e) => [h.p([h.Class("error")], [e])] }),
            h.p([], ["Cadencia usa Intervals.icu como fuente de verdad: tus actividades, tu bienestar y tu calendario siguen allí."]),
            h.a([h.Class("connect"), h.Href("/auth/intervals/start")], ["Conectar con Intervals.icu"]),
          ]),
        ]
      : [
          ...(model.readsOnline ? [] : [h.p([h.Class("muted"), h.AriaLive("polite")], ["Sin conexión con Cadencia. Reintentando…"])]),
          ...Option.match(model.error, {
            onNone: () => [],
            onSome: (e) => [
              h.p([h.Class("error"), h.AriaLive("polite")], [
                e,
                ...(model.needsReconnect ? [" ", reconnectLink(h, "Conectar de nuevo")] : []),
              ]),
            ],
          }),
          ...writeStatus(model, h),
          ...Option.match(model.notice, { onNone: () => [], onSome: (n) => [h.p([h.Class("muted"), h.AriaLive("polite")], [n])] }),
          // The page itself: what a move between pages animates, busy while the history it shows is read.
          h.main(
            [
              h.Class(historyOnScreen(model) && AsyncData.isRefreshing(model.history) ? "page refreshing" : "page"),
              h.AriaBusy(historyOnScreen(model) && AsyncData.isPending(model.history)),
            ],
            AppRoute.match(model.route, {
              Home: () => Home.view(model, h),
              Coach: () => Coach.view(model, h),
              Plan: () => Plan.view(model, h),
              History: () => History.view(model, h),
              Profile: () => Profile.view(model, h),
              NotFound: ({ path }) => NotFound.view(h, path),
            }),
          ),
        ]),
  ]),
});
