import type { HtmlBuilder } from "foldkit/html";
import { Message } from "../message.ts";
import { busy, Model } from "../model.ts";
import { liveContent } from "../view/live.ts";
import { pill } from "../view/pill.ts";
import { refusalText } from "../view/refusal.ts";

export const view = (model: Model, h: HtmlBuilder<Message>) => [
  h.div([h.Class("card")], [
    h.h2([], ["Conversación de este mes"]),
    h.p([h.Class("muted")], [
      "Para escribir al coach usa Cadencia en el iPhone: la respuesta necesita la IA. Aquí puedes aceptar o descartar lo que te propone.",
    ]),
    ...liveContent(h, model.thread, (thread) =>
      thread.messages.length === 0
        ? [h.p([h.Class("muted")], ["Todavía no hay mensajes este mes."])]
        : thread.messages.map((m) =>
          h.keyed("div")(m.messageId, [h.Class(`message ${m.role}`)], [
            h.p([], [m.text]),
            ...(m.intent
              ? [
                  h.p([h.Class("muted")], [`Propuesta: ${m.intent.summary}`]),
                  m.intentStatus === "proposed"
                    ? h.div([h.Class("row")], [
                        h.button(
                          [
                            h.Class("primary"),
                            h.Disabled(busy(model)),
                            h.OnClick(Message.ClickedAcceptIntent({ conversationId: thread.conversationId, messageId: m.messageId })),
                          ],
                          ["Aceptar"],
                        ),
                        h.button(
                          [
                            h.Class("secondary"),
                            h.Disabled(busy(model)),
                            h.OnClick(Message.ClickedDismissIntent({ conversationId: thread.conversationId, messageId: m.messageId })),
                          ],
                          ["Descartar"],
                        ),
                      ])
                    : pill(
                        h,
                        m.intentStatus === "applied"
                          ? "Aplicada al plan"
                          : m.intentStatus === "refused"
                            ? `El plan la rechazó: ${refusalText(m.refusal)}`
                            : m.intentStatus === "dismissed"
                              ? "Descartada"
                              : "Aceptada",
                        m.intentStatus === "applied" ? "good" : m.intentStatus === "refused" ? "bad" : "info",
                      ),
                ]
              : []),
          ]),
        ),
    ),
  ]),
];
