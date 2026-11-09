import type { Confidence, RiderReport, RiderType } from "@cadencia/coach/RiderProfile/RiderReport";
import * as Array from "effect/Array";
import * as Option from "effect/Option";
import type { HtmlBuilder } from "foldkit/html";
import { Message } from "../message.ts";
import { Model } from "../model.ts";
import { fieldView } from "../view/field.ts";
import { historyCards } from "../view/history.ts";
import { liveContent } from "../view/live.ts";

// The rider profile reads as it does in Cadencia for iPhone, in the same words.
const RIDER_TYPES: Record<RiderType, string> = {
  climber: "Escalador",
  puncheur: "Especialista en repechos",
  sprinter: "Velocista",
  timeTrialist: "Contrarrelojista",
  endurance: "Fondista",
  allRounder: "Ciclista polivalente",
  developing: "Descubriendo tu tipo de ciclista",
};

const CONFIDENCES: Record<Confidence, string> = {
  limited: "Primera impresión · evidencia limitada",
  moderate: "Patrón emergente · confianza moderada",
  high: "Patrón consistente · confianza alta",
};

/** What the report says about the rider, in the order iOS shows it. */
const INSIGHTS = [
  ["strengths", "Dónde destacas"],
  ["development", "Oportunidades para mejorar"],
  ["evidence", "La evidencia"],
  ["caveats", "Lo que falta por conocer"],
] as const satisfies ReadonlyArray<readonly [keyof RiderReport, string]>;

const scale = (model: Model, h: HtmlBuilder<Message>, label: string, field: "mood" | "motivation" | "soreness" | "fatigue") =>
  fieldView(h, `declaration-${field}`, label, model.declaration[field], (attributes) =>
    h.select(
      [...attributes, h.OnChange((value) => Message.UpdatedDeclaration({ field, value }))],
      [h.option([h.Value("")], ["—"]), ...["1", "2", "3", "4"].map((n) => h.option([h.Value(n)], [n]))],
    ),
  );

export const view = (model: Model, h: HtmlBuilder<Message>) => {
  return [
    ...historyCards(model, h, "Tu perfil", ({ athlete }) => [
      h.div([h.Class("card")], [
        h.h2([], [athlete.name ?? "Tu perfil"]),
        h.p([], [`Peso: ${athlete.weight != null ? `${athlete.weight} kg` : "—"} · FTP: ${athlete.ftp != null ? `${athlete.ftp} W` : "—"}`]),
        h.p([h.Class("muted")], ["Estos datos viven en Intervals.icu."]),
      ]),
    ]),
    h.div([h.Class("card")], [
      h.h2([], ["Cómo estás hoy"]),
      h.p([h.Class("muted")], ["Se guarda en el bienestar de hoy en Intervals.icu (escala de Intervals, 1 a 4)."]),
      h.form([h.Class("row"), h.OnSubmit(Message.SubmittedDeclaration())], [
        h.fieldset([h.Disabled(model.savingDeclaration)], [
          scale(model, h, "Ánimo", "mood"),
          scale(model, h, "Motivación", "motivation"),
          scale(model, h, "Agujetas", "soreness"),
          scale(model, h, "Fatiga", "fatigue"),
          fieldView(h, "declaration-weight", "Peso (kg)", model.declaration.weight, (attributes) =>
            h.input([...attributes, h.Type("number"), h.OnInput((value) => Message.UpdatedDeclaration({ field: "weight", value }))]),
          ),
          fieldView(h, "declaration-comments", "Comentario", model.declaration.comments, (attributes) =>
            h.input([...attributes, h.Type("text"), h.OnInput((value) => Message.UpdatedDeclaration({ field: "comments", value }))]),
          ),
          h.button([h.Class("primary"), h.Type("submit")], ["Guardar en Intervals"]),
        ]),
      ]),
    ]),
    h.div([h.Class("card")], [
      h.h2([], ["Perfil de ciclista"]),
      ...liveContent(h, model.profile, (profile) => [
        Option.getOrElse(
          Option.flatMap(profile, (card) => Option.map(Option.fromNullishOr(card.report), (report) => riderReportView(h, report, card.model))),
          () => h.p([h.Class("muted")], ["Se genera con la IA desde Cadencia para iPhone."]),
        ),
      ]),
    ]),
  ];
};

const riderReportView = (h: HtmlBuilder<Message>, report: RiderReport, model: string | null) =>
  h.div([h.Class("report")], [
    h.h3([], [RIDER_TYPES[report.riderType]]),
    h.p([h.Class("muted")], [CONFIDENCES[report.confidence]]),
    h.p([], [h.strong([], [report.headline])]),
    h.p([], [report.summary]),
    h.details([], [
      h.summary([], ["Lo que muestra tu historial"]),
      ...Array.flatMap(INSIGHTS, ([field, title]) =>
        Array.match(report[field], {
          onEmpty: () => [],
          onNonEmpty: (items) => [h.h4([], [title]), h.ul([], items.map((item) => h.li([], [item])))],
        }),
      ),
      h.p([h.Class("muted")], [
        `${report.rideCount} salidas · ${report.oldest} → ${report.newest}`,
        ...Array.fromNullishOr(model).map((name) => ` · ${name}`),
      ]),
    ]),
  ]);
