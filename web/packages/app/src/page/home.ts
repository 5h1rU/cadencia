import { addDays } from "@cadencia/kernel/Calendar/Day";
import * as Option from "effect/Option";
import { AsyncData } from "foldkit";
import type { HtmlBuilder } from "foldkit/html";
import { DECISION_ABSENCES, decisionAbsence } from "../domain/decisionAbsence.ts";
import { Message } from "../message.ts";
import { Model } from "../model.ts";
import { liveContent } from "../view/live.ts";
import { pill } from "../view/pill.ts";
import { refusalText } from "../view/refusal.ts";
import { sessionsTable, workoutLine } from "../view/session.ts";

/** Today's decision, once iOS has made one: the card with its note, or a card saying it will come. */
const decisionCard = (model: Model, h: HtmlBuilder<Message>) => {
  const made = AsyncData.getData(model.decision).pipe(
    Option.flatten,
    Option.flatMap((decision) =>
      decision.status === "none" ? Option.none() : Option.map(Option.fromNullishOr(decision.note), (note) => ({ decision, note })),
    ),
  );
  return Option.match(made, {
    onNone: () =>
      h.div([h.Class("card")], [
        h.h2([], ["Hoy"]),
        ...liveContent(h, model.decision, () => [
          // Until the plan is read, say what holds whatever it says.
          h.p([h.Class("muted")], [
            DECISION_ABSENCES[
              Option.match(AsyncData.getData(model.plan), {
                onNone: () => "notYet" as const,
                onSome: (plan) => decisionAbsence(plan, model.today),
              })
            ],
          ]),
        ]),
      ]),
    onSome: ({ decision, note }) =>
      h.div([h.Class("card")], [
        h.h2([], [note.headline]),
        decision.status === "accepted"
          ? pill(h, "Aceptada por el plan", "good")
          : decision.status === "refused"
            ? pill(h, `El plan la rechazó: ${refusalText(decision.refusal)}`, "bad")
            : pill(h, "Esperando al plan", "info"),
        h.p([], [note.body]),
        h.p([], [note.session]),
        ...(note.watch ? [h.p([h.Class("muted")], [note.watch])] : []),
        ...(decision.workout ? [h.p([h.Class("muted")], [workoutLine(decision.workout)])] : []),
        // The plan keeps the last proposal it accepted, which can be an earlier attempt.
        ...(decision.planHolds !== null && decision.planHolds.attempt !== decision.attempt
          ? [h.p([], [`El plan mantiene: ${decision.planHolds.note.headline} (${workoutLine(decision.planHolds.workout)})`])]
          : []),
        ...(decision.awaiting.length > 0 && decision.status !== "pending"
          ? [h.p([h.Class("muted")], ["Hay otra propuesta esperando la respuesta del plan."])]
          : []),
        ...(decision.evidence
          ? [h.p([h.Class("muted")], [`Readiness: ${decision.evidence.readiness.summary} (${decision.evidence.readiness.score}/100)`])]
          : []),
        h.p([h.Class("muted")], [`Interpretado en iOS con ${decision.model ?? "?"}.`]),
      ]),
  });
};

export const view = (model: Model, h: HtmlBuilder<Message>) => [
  decisionCard(model, h),
  h.div([h.Class("card")], [
    h.h2([], ["Próximos 7 días"]),
    ...liveContent(h, model.plan, (plan) => {
      const upcoming = Option.match(plan, {
        onNone: () => [],
        onSome: ({ sessions }) => sessions.filter((s) => s.day >= model.today && s.day <= addDays(model.today, 6)),
      });
      return [
        upcoming.length === 0
          ? h.p([h.Class("muted")], ["No hay sesiones planificadas esta semana."])
          : sessionsTable(h, upcoming, Option.match(plan, { onNone: () => [], onSome: (p) => p.calendarProblems })),
      ];
    }),
  ]),
];
