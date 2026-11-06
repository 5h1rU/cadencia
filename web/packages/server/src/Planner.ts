import { Planner } from "@cadencia/coach/Planner.external";
import { system } from "@cadencia/kernel/Actor";
import { CoachPlanningApi } from "@cadencia/planning/CoachPlanningApi.api";
import { PlanId } from "@cadencia/planning/Plan/Plan.id";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import { layerOverPlanning } from "./Hosting.ts";
import { actingAs } from "./Session.ts";

/** A refusal in plain words: the rejection's tag and its evidence. */
const describe = (rejection: { readonly _tag: string }): string => {
  const { _tag, ...evidence } = rejection as { readonly _tag: string } & Record<string, unknown>;
  const fields = Object.entries(evidence).filter(([k]) => !k.startsWith("_") && k !== "stack" && k !== "message");
  return fields.length === 0 ? _tag : `${_tag}: ${fields.map(([k, v]) => `${k}=${JSON.stringify(v)}`).join(", ")}`;
};

const accepted = { accepted: true, reason: null } as const;
const refused = (rejection: { readonly _tag: string }) => Effect.succeed({ accepted: false, reason: describe(rejection) });

/**
 * The Coach's `Planner`, answered by the Planning model in this process. The
 * coach acts as the system: Planning's own rules still decide.
 */
export const PlanningPlanner = Planner.toLayer(
  Effect.gen(function* () {
    const planning = yield* CoachPlanningApi.Client;
    return {
      concretizeSession: ({ planId, day, workout, evidence }) =>
        planning.ConcretizeSession(PlanId.make(planId), { day, workout, evidence }).pipe(
          Effect.as(accepted),
          Effect.catch(refused),
        ),
      reviseWeek: ({ planId, limits }) =>
        planning.ReviseWeek(PlanId.make(planId), { limits }).pipe(Effect.as(accepted), Effect.catch(refused)),
      createPlan: ({ planId, draft }) =>
        planning
          .CreatePlan(PlanId.make(planId), {
            athleteId: draft.athleteId,
            title: draft.title,
            goal: draft.goal,
            startDay: draft.startDay,
            endDay: draft.endDay,
            phases: draft.phases,
            longRideWeekday: draft.longRideWeekday,
            event: draft.event ? { ...draft.event, objective: draft.objective } : null,
            sessions: draft.sessions,
          })
          .pipe(Effect.as(accepted), Effect.catch(refused)),
    };
  }),
).pipe(
  Layer.provide(layerOverPlanning(CoachPlanningApi.layerClientInProcess.pipe(Layer.provide(actingAs(system("coach")))))),
);
