import { CurrentPlanState } from "@cadencia/planning/Plan/CurrentPlan.view";
import type { PlannedSession } from "@cadencia/planning/Plan/PlannedSession";
import * as Option from "effect/Option";
import { AsyncData } from "foldkit";
import type { HtmlBuilder } from "foldkit/html";
import { Message } from "../message.ts";
import { busy, Model } from "../model.ts";
import { fieldView } from "../view/field.ts";
import { liveContent } from "../view/live.ts";
import { pill } from "../view/pill.ts";
import { sessionsTable } from "../view/session.ts";

/** Sessions Cadencia still owns and that still ride: the only ones the plan lets the athlete move. */
export const isMovable = (session: PlannedSession) =>
  session.status === "provisional" || session.status === "concrete" || session.status === "published";

export const view = (model: Model, h: HtmlBuilder<Message>) =>
  Option.match(AsyncData.getData(model.plan), {
    onNone: () => [h.div([h.Class("card")], [h.h2([], ["Plan"]), ...liveContent(h, model.plan, () => [])])],
    onSome: (plan) => planCards(model, h, plan),
  });

const planCards = (model: Model, h: HtmlBuilder<Message>, plan: Option.Option<typeof CurrentPlanState.Type>) =>
  Option.match(plan, {
    onNone: () => [
      h.div([h.Class("card")], [
        h.h2([], ["Sin plan"]),
        h.p([h.Class("muted")], ["Los planes se crean con la consulta del coach en Cadencia para iPhone."]),
      ]),
    ],
    onSome: (plan) => [
      h.div([h.Class("card")], [
        h.h2([], [plan.title ?? "Plan"]),
        pill(h, plan.status === "active" ? "Activo" : "Retirado", plan.status === "active" ? "good" : "warn"),
        ...(plan.objective === null ? [] : [h.p([], [plan.objective])]),
        h.p([h.Class("muted")], [`${plan.startDay ?? ""} → ${plan.endDay ?? ""}`]),
        h.ul([], plan.phases.map((p) => h.li([], [`Semanas ${p.startWeek}–${p.endWeek}: ${p.summary}`]))),
      ]),
      h.div([h.Class("card")], [h.h2([], ["Sesiones"]), sessionsTable(h, plan.sessions, plan.calendarProblems)]),
      ...(plan.status === "active"
        ? [
            h.div([h.Class("card")], [
              h.h2([], ["Mover una sesión"]),
              h.p([h.Class("muted")], ["Las sesiones que cambiaste en Intervals.icu se mueven allí."]),
              h.form([h.Class("row"), h.OnSubmit(Message.SubmittedMove())], [
                h.fieldset([h.Disabled(busy(model))], [
                  fieldView(h, "move-session", "Sesión", model.move.sessionId, (attributes) =>
                    h.select(
                      [...attributes, h.OnChange((value) => Message.UpdatedMove({ field: "sessionId", value }))],
                      [
                        h.option([h.Value("")], ["Elige…"]),
                        ...plan.sessions
                          .filter((s) => s.day >= model.today && isMovable(s))
                          .map((s) => h.option([h.Value(s.sessionId)], [`${s.day} · ${s.title}`])),
                      ],
                    ),
                  ),
                  fieldView(h, "move-day", "Nuevo día", model.move.toDay, (attributes) =>
                    h.input([...attributes, h.Type("date"), h.OnInput((value) => Message.UpdatedMove({ field: "toDay", value }))]),
                  ),
                  h.button([h.Class("primary"), h.Type("submit")], ["Mover"]),
                ]),
              ]),
            ]),
            h.div([h.Class("card")], [
              h.h2([], ["Requisito para un día"]),
              h.p([h.Class("muted")], ["El plan nunca te propondrá más minutos de los que indiques, y ajusta la sesión de ese día al momento."]),
              h.form([h.Class("row"), h.OnSubmit(Message.SubmittedRequirement())], [
                h.fieldset([h.Disabled(busy(model))], [
                  fieldView(h, "requirement-day", "Día", model.requirement.day, (attributes) =>
                    h.input([...attributes, h.Type("date"), h.OnInput((value) => Message.UpdatedRequirement({ field: "day", value }))]),
                  ),
                  fieldView(h, "requirement-minutes", "Máximo de minutos", model.requirement.maxMinutes, (attributes) =>
                    h.input([
                      ...attributes,
                      h.Type("number"),
                      h.Min("0"),
                      h.OnInput((value) => Message.UpdatedRequirement({ field: "maxMinutes", value })),
                    ]),
                  ),
                  fieldView(h, "requirement-note", "Nota", model.requirement.instructions, (attributes) =>
                    h.input([
                      ...attributes,
                      h.Type("text"),
                      h.OnInput((value) => Message.UpdatedRequirement({ field: "instructions", value })),
                    ]),
                  ),
                  h.button([h.Class("primary"), h.Type("submit")], ["Guardar"]),
                ]),
              ]),
            ]),
            h.div([h.Class("card")], [
              h.h2([], ["Retirar el plan"]),
              h.p([h.Class("muted")], ["Sus sesiones desde hoy salen del calendario de Intervals.icu."]),
              model.confirmRetire
                ? h.div([h.Class("row")], [
                    h.button(
                      [h.Class("primary"), h.Disabled(busy(model)), h.OnClick(Message.ClickedConfirmRetire())],
                      ["Sí, retirar el plan"],
                    ),
                    h.button([h.Class("secondary"), h.OnClick(Message.ClickedCancelRetire())], ["Cancelar"]),
                  ])
                : h.button([h.Class("secondary"), h.Disabled(busy(model)), h.OnClick(Message.ClickedRetire())], ["Retirar el plan"]),
            ]),
          ]
        : []),
    ],
  });
