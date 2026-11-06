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
