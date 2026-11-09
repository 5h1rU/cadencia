import type { SessionKind } from "@cadencia/kernel/Training/SessionKind";
import { totalMinutes, type Workout } from "@cadencia/kernel/Training/Workout";
import type { CalendarProblem } from "@cadencia/planning/Plan/Calendar.external";
import { CurrentPlanState } from "@cadencia/planning/Plan/CurrentPlan.view";
import type { PlannedSession, SessionStatus } from "@cadencia/planning/Plan/PlannedSession";
import type { HtmlBuilder } from "foldkit/html";
import { Message } from "../message.ts";
import { pill } from "./pill.ts";
import { reconnectLink } from "./reconnect.ts";

const KIND: Record<SessionKind, string> = {
  rest: "Descanso",
  recovery: "Recuperación",
  endurance: "Resistencia",
  tempo: "Sweet spot",
  threshold: "Umbral",
  vo2max: "VO₂max",
  openerActivation: "Activación",
  longRide: "Tirada larga",
  groupRide: "Grupeta",
  race: "Carrera",
  strength: "Fuerza",
};

const STATUS: Record<SessionStatus, readonly [string, string]> = {
  provisional: ["Provisional", "info"],
  concrete: ["Concretada", "info"],
  published: ["En Intervals", "good"],
  skipped: ["Omitida", "warn"],
  changedInIntervals: ["Cambiada en Intervals", "warn"],
  removedInIntervals: ["Borrada en Intervals", "bad"],
};

const CALENDAR_PROBLEMS: Record<CalendarProblem, string> = {
  notConnected: "Intervals.icu no está conectado",
  refused: "Intervals.icu rechazó esta sesión",
};

const minutesOf = (workout: Workout) => Math.round(totalMinutes(workout));

export const workoutLine = (workout: Workout) => `${workout.name} · ${KIND[workout.kind]} · ${minutesOf(workout)} min`;

export const sessionsTable = (
  h: HtmlBuilder<Message>,
  sessions: ReadonlyArray<PlannedSession>,
  problems: (typeof CurrentPlanState.Type)["calendarProblems"],
) =>
  h.div([h.Class("scroll")], [
    h.table([], [
      h.thead([], [h.tr([], [h.th([], ["Día"]), h.th([], ["Sesión"]), h.th([], ["Min"]), h.th([], ["Estado"])])]),
      h.tbody(
        [],
        sessions.map((s) => {
          const [label, tone] = STATUS[s.status];
          const problem = problems.find((p) => p.sessionId === s.sessionId);
          return h.keyed("tr")(s.sessionId, [], [
            h.td([], [s.day]),
            h.td([], [`${s.workout?.name ?? s.title} · ${KIND[s.kind]}`]),
            h.td([], [String(s.workout ? minutesOf(s.workout) : s.targetMinutes)]),
            h.td([], [
              pill(h, label, tone),
              ...(problem === undefined
                ? []
                : [
                    h.p([h.Class("error")], [
                      CALENDAR_PROBLEMS[problem.problem],
                      ...(problem.problem === "notConnected" ? [" · ", reconnectLink(h, "Conectar de nuevo")] : []),
                    ]),
                  ]),
            ]),
          ]);
        }),
      ),
    ]),
  ]);
