import type { PlanId } from "@cadencia/kernel/Plan.id";
import * as DateTime from "effect/DateTime";

/**
 * When a plan was created, which orders an athlete's plans: the newest one is
 * current. Events from different plans can arrive in any order, so arrival
 * says nothing about which plan came last.
 */
export interface PlanCreation {
  readonly planId: PlanId;
  readonly createdAt: DateTime.Utc;
}

/** Whether `a` was created before `b`. Plans created in the same millisecond are ordered by id. */
export const isOlder = (a: PlanCreation, b: PlanCreation): boolean => {
  const order = DateTime.Order(a.createdAt, b.createdAt);
  return order === 0 ? a.planId < b.planId : order < 0;
};
