import * as Schema from "effect/Schema";
import { Refusal } from "./Refusal.ts";

/** What the Planning model said about a proposal. */
export const PlanAnswer = Schema.Union([
  Schema.TaggedStruct("Accepted", {}),
  Schema.TaggedStruct("Refused", { refusal: Refusal }),
]);
export type PlanAnswer = typeof PlanAnswer.Type;
