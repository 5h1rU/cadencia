import { EntityKey } from "@cadencia/kernel/EntityKey";
import { planIdFor } from "@cadencia/kernel/Plan.id";
import { describe, expect, it } from "@effect/vitest";
import * as DateTime from "effect/DateTime";
import type { PlanCreated } from "../src/Plan/CreatePlan.command.ts";
import { PlanRetired } from "../src/Plan/RetirePlan.command.ts";
import { CurrentPlan } from "../src/Plan/CurrentPlan.view.ts";
import { Plan } from "../src/Plan/Plan.aggregate.ts";
import { anaId, planCreated, planId } from "./fixtures.ts";

const older = planId;
const newer = planIdFor(anaId, EntityKey.make("6a1f0c3e-2b4d-4c5e-9f60-718293a4b5c6"));

type Delivery = Parameters<typeof CurrentPlan.evolve>[1];

/** One plan event, as the view receives it: from its plan, committed at `at`. */
const delivery = (id: typeof planId, event: PlanCreated | PlanRetired, at: string, seq: number) =>
  ({
  name: "Plan",
  event,
  source: Plan.ref(id),
  envelope: { id, stream: `Plan/${id}`, seq, at: DateTime.makeUnsafe(at), commandId: `${id}:${seq}`, correlationId: `${id}:${seq}` },
  }) as Delivery;

const olderCreated = delivery(older, planCreated(), "2026-11-11T08:00:00Z", 1);
const olderRetired = delivery(older, new PlanRetired({ withdrawn: [] }), "2026-11-12T08:00:01Z", 2);
const newerCreated = delivery(newer, planCreated([]), "2026-11-12T08:00:00Z", 1);

/**
 * Every order the two plans' events can arrive in: each plan's own events stay
 * in order, as Alchemy guarantees, but the plans interleave freely.
 */
const interleavings = [
  [olderCreated, olderRetired, newerCreated],
  [olderCreated, newerCreated, olderRetired],
  [newerCreated, olderCreated, olderRetired],
];

describe("the current plan", () => {
  it.each(interleavings.map((order, i) => [i, order] as const))(
    "is the newest plan, active, whatever order its events arrive in (%i)",
    (_, order) => {
      type State = typeof CurrentPlan.State.Type;
      const state = order.reduce<State | null>((s, input) => CurrentPlan.evolve(s, input) as State, null);
      expect(state).toMatchObject({ planId: newer, status: "active" });
    },
  );
});
