import * as Schema from "effect/Schema";

/** What a plan trains for. Raw values match `GoalKind` in Cadencia iOS. */
export const GoalKind = Schema.Literals(["climbing", "ftp", "durability", "endurance", "vo2max", "event", "strength"]);
export type GoalKind = typeof GoalKind.Type;
