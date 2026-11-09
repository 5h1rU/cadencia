import type { RefusalReason } from "@cadencia/coach/Refusal";

const REFUSALS: Record<RefusalReason, string> = {
  planNotActive: "el plan no está activo",
  dayNotPlanned: "ese día no tiene sesión",
  availabilityExceeded: "supera el tiempo disponible",
  intensityAfterHardTraining: "hay entrenamiento duro el mismo día o el anterior",
  hardensPlan: "endurecía una sesión suave del plan",
  purposeMismatch: "no encaja con el propósito de la sesión",
  invalidPlan: "el borrador no es un plan válido",
  planAlreadyExists: "el plan ya existe",
  implausibleToday: "la fecha del dispositivo no cuadraba",
  notYours: "no tienes permiso",
};

export const refusalText = (refusal: { readonly reason: RefusalReason } | null) => (refusal === null ? "" : REFUSALS[refusal.reason]);
