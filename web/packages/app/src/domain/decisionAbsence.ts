import type { Day } from "@cadencia/kernel/Calendar/Day";
import { CurrentPlanState } from "@cadencia/planning/Plan/CurrentPlan.view";
import * as Option from "effect/Option";

/**
 * Why the web has no decision for today. iOS records the coach's day on the
 * backend only for the plan to confirm it (`AppModel.askCoachForToday`): with
 * no active plan covering today, or a rest on a day the plan leaves free,
 * the decision stays on the iPhone and never reaches the web.
 */
export type DecisionAbsence = "noPlan" | "freeDay" | "notYet";

export const decisionAbsence = (plan: Option.Option<typeof CurrentPlanState.Type>, today: Day): DecisionAbsence =>
  Option.match(plan, {
    onNone: () => "noPlan",
    onSome: (p) =>
      p.status !== "active" || p.startDay === null || p.endDay === null || today < p.startDay || today > p.endDay
        ? "noPlan"
        : p.sessions.some((s) => s.day === today && s.status !== "skipped")
          ? "notYet"
          : "freeDay",
  });

export const DECISION_ABSENCES: Record<DecisionAbsence, string> = {
  noPlan:
    "No hay un plan activo para hoy, así que la decisión del coach se queda en el iPhone. Aquí solo aparece la que confirma el plan.",
  freeDay:
    "Hoy el plan no tiene sesión. Si el coach propone descansar, la decisión se queda en el iPhone; si propone entrenar, aparecerá aquí cuando el plan responda.",
  notYet: "La decisión de hoy aparecerá cuando abras Cadencia en el iPhone.",
};
