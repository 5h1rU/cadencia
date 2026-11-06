import * as Schema from "effect/Schema";

/** What a session is for. The raw values match `SessionKind` in Cadencia iOS. */
export const SessionKind = Schema.Literals([
  "rest",
  "recovery",
  "endurance",
  "tempo",
  "threshold",
  "vo2max",
  "openerActivation",
  "longRide",
  "groupRide",
  "race",
  "strength",
]);
export type SessionKind = typeof SessionKind.Type;

/** Kinds that load the athlete with sustained intensity. */
export const isHard = (kind: SessionKind): boolean =>
  kind === "tempo" || kind === "threshold" || kind === "vo2max" || kind === "race";

/** Kinds whose purpose is easy riding: a proposal for one of these days may not add intensity. */
export const isEasy = (kind: SessionKind): boolean =>
  kind === "recovery" || kind === "endurance" || kind === "longRide";
