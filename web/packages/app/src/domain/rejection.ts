import { Day } from "@cadencia/kernel/Calendar/Day";
import { CoachClient, PlanningClient } from "../client.ts";

type PlanningResult = typeof PlanningClient.Message.Type;
type CoachResult = typeof CoachClient.Message.Type;
/** The rejections a command's derived result can carry. */
type RejectionOf<Result, Tag extends string> =
  Extract<Result, { readonly _tag: Tag }> extends { readonly failure: infer F }
    ? F extends { readonly _tag: "Rejected"; readonly rejection: infer R }
      ? R
      : never
    : never;

/** One text per rejection a command declares: adding a rejection to the domain fails the build here. */
type Explanations<R extends { readonly _tag: string }> = {
  readonly [T in R["_tag"]]: (rejection: Extract<R, { readonly _tag: T }>) => string;
};

export const explain =
  <R extends { readonly _tag: string }>(texts: Explanations<R>) =>
  (rejection: R): string =>
    (texts[rejection._tag as R["_tag"]] as (r: R) => string)(rejection);

export const notYours = () => "Esto pertenece a otra cuenta. Vuelve a entrar con la tuya de Intervals.icu.";
const planNotActive = () => "El plan ya no está activo.";
const dayOutsidePlan = ({ startDay, endDay }: { readonly startDay: Day; readonly endDay: Day }) =>
  `Ese día está fuera del plan (${startDay} → ${endDay}).`;
const noOpenIntent = () => "Esa propuesta ya no está pendiente.";

export const MOVE_REJECTIONS: Explanations<RejectionOf<PlanningResult, "FailedMoveSession">> = {
  PlanNotActive: planNotActive,
  SessionNotFound: () => "Esa sesión ya no existe en el plan.",
  SessionNotMovable: ({ status }) =>
    status === "skipped"
      ? "Esa sesión se omitió porque ese día no tenías disponibilidad: ya no se puede mover."
      : "Esa sesión la cambiaste en Intervals.icu, que manda: muévela allí.",
  DayOutsidePlan: dayOutsidePlan,
  DayTaken: ({ day }) => `El ${day} ya tiene otra sesión.`,
  NotYours: notYours,
};

export const REQUIREMENT_REJECTIONS: Explanations<RejectionOf<PlanningResult, "FailedRecordDayRequirement">> = {
  PlanNotActive: planNotActive,
  DayOutsidePlan: dayOutsidePlan,
  NotYours: notYours,
};

export const RETIRE_REJECTIONS: Explanations<RejectionOf<PlanningResult, "FailedRetirePlan">> = {
  PlanNotActive: planNotActive,
  ImplausibleToday: () => "La fecha de este dispositivo no cuadra con la de Cadencia. Revisa la fecha y la hora.",
  NotYours: notYours,
};

export const ACCEPT_REJECTIONS: Explanations<RejectionOf<CoachResult, "FailedAcceptIntent">> = {
  NoOpenIntent: noOpenIntent,
  IntentExpired: () => "Esa propuesta era para días que ya han pasado.",
  NotYours: notYours,
};

export const DISMISS_REJECTIONS: Explanations<RejectionOf<CoachResult, "FailedDismissIntent">> = {
  NoOpenIntent: noOpenIntent,
  NotYours: notYours,
};
