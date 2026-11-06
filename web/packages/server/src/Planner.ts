import type { PlanAnswer, RefusalReason } from "@cadencia/coach/CoachShape";
import { Planner } from "@cadencia/coach/Planner.external";
import { system } from "@cadencia/identity/Actor";
import { Paragraph } from "@cadencia/kernel/Text";
import { CoachPlanningApi } from "@cadencia/planning/CoachPlanningApi.api";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as Option from "effect/Option";
import * as Schema from "effect/Schema";
import { layerOverPlanning } from "./Hosting.ts";
import { actingAs } from "./Session.ts";

/**
 * Each Planning rejection in the coach's words. This is the anti-corruption
 * layer between the two models: Coach never sees Planning's rejection classes.
 */
const REASONS: Record<string, RefusalReason> = {
  PlanNotActive: "planNotActive",
  DayNotPlanned: "dayNotPlanned",
  DayOutsidePlan: "dayOutsidePlan",
  DayTaken: "dayTaken",
  SessionNotFound: "sessionNotFound",
  AvailabilityExceeded: "availabilityExceeded",
  IntensityAfterHardTraining: "intensityAfterHardTraining",
  HardensPlannedSession: "hardensPlan",
  PurposeMismatch: "purposeMismatch",
  InvalidPlan: "invalidPlan",
  PlanAlreadyExists: "planAlreadyExists",
  NotYours: "notYours",
};

/** The rejection's evidence as one line, such as `allowedMinutes=45, proposedMinutes=60`. */
const detailOf = (rejection: object): Paragraph | null => {
  const evidence = Object.entries(rejection).filter(([k]) => !k.startsWith("_") && k !== "stack" && k !== "message");
  if (evidence.length === 0) return null;
  return Option.getOrNull(
    Schema.decodeUnknownOption(Paragraph)(evidence.map(([k, v]) => `${k}=${JSON.stringify(v)}`).join(", ")),
  );
};

const accepted: PlanAnswer = { _tag: "Accepted" };

const refused = (rejection: { readonly _tag: string }): Effect.Effect<{ readonly answer: PlanAnswer }> => {
  const reason = REASONS[rejection._tag];
  // A rejection without a translation is a contract this adapter does not know yet: a defect, not a refusal.
  if (!reason) return Effect.die(new Error(`Untranslated Planning rejection: ${rejection._tag}`));
  return Effect.succeed({ answer: { _tag: "Refused", refusal: { reason, detail: detailOf(rejection) } } });
};

/**
 * The Coach's `Planner`, answered by the Planning model in this process. The
 * coach acts as the system: Planning's own rules still decide. Each request's
 * id is the command's id, so a policy that runs again gets the same answer
 * instead of acting twice.
 */
export const PlanningPlanner = Planner.toLayer(
  Effect.gen(function* () {
    const planning = yield* CoachPlanningApi.Client;
    return {
      concretizeSession: ({ requestId, planId, day, workout, evidence }) =>
        planning
          .ConcretizeSession(planId, { day, workout, evidence }, { commandId: requestId })
          .pipe(Effect.as({ answer: accepted }), Effect.catch(refused)),
      reviseWeek: ({ requestId, planId, limits }) =>
        planning.ReviseWeek(planId, { limits }, { commandId: requestId }).pipe(Effect.as({ answer: accepted }), Effect.catch(refused)),
      createPlan: ({ requestId, planId, draft }) =>
        planning
          .CreatePlan(
            planId,
            {
            athleteId: draft.athleteId,
            title: draft.title,
            goal: draft.goal,
            startDay: draft.startDay,
            endDay: draft.endDay,
            phases: draft.phases,
            longRideWeekday: draft.longRideWeekday,
            event: draft.event ? { ...draft.event, objective: draft.objective } : null,
            sessions: draft.sessions,
            },
            { commandId: requestId },
          )
          .pipe(Effect.as({ answer: accepted }), Effect.catch(refused)),
    };
  }),
).pipe(
  Layer.provide(layerOverPlanning(CoachPlanningApi.layerClientInProcess.pipe(Layer.provide(actingAs(system("coach")))))),
);
