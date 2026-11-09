import type { HtmlBuilder } from "foldkit/html";
import { Message } from "../message.ts";
import { homeRouter } from "../route.ts";

export const view = (h: HtmlBuilder<Message>, path: string) => [
  h.div([h.Class("card")], [
    h.h2([], ["Esta página no existe"]),
    h.p([h.Class("muted")], [`No hay nada en ${path}.`]),
    h.a([h.Href(homeRouter())], ["Volver a hoy"]),
  ]),
];
