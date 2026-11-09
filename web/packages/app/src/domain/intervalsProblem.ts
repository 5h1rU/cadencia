import * as Schema from "effect/Schema";

/** Why an Intervals.icu read or write didn't happen. */
export const IntervalsProblem = Schema.Literals(["signedOut", "notConnected", "unavailable"]);
export type IntervalsProblem = typeof IntervalsProblem.Type;

/**
 * What a failed Intervals.icu call means to the athlete, by the status the
 * server declares for it: 401 signed out, 409 Intervals not connected any
 * more, anything else Intervals not answering.
 */
export const intervalsProblemOf = (status: number): IntervalsProblem =>
  status === 401 ? "signedOut" : status === 409 ? "notConnected" : "unavailable";

export const SIGNED_OUT = "Tu sesión ha terminado. Vuelve a conectar con Intervals.icu.";

export const INTERVALS_PROBLEMS: Record<Exclude<IntervalsProblem, "signedOut">, string> = {
  notConnected: "Intervals.icu no está conectado.",
  unavailable: "No se pudo hablar con Intervals.icu. Vuelve a intentarlo.",
};

export const intervalsProblemText = (problem: IntervalsProblem) =>
  problem === "signedOut" ? SIGNED_OUT : INTERVALS_PROBLEMS[problem];
