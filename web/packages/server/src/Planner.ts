import type { PlanAnswer } from "@cadencia/coach/PlanAnswer";
import { Planner } from "@cadencia/coach/Planner.external";
import type { RefusalReason } from "@cadencia/coach/Refusal";
import { athlete } from "@cadencia/identity/Actor";
import type { AthleteId } from "@cadencia/identity/Athlete.id";
import { Paragraph } from "@cadencia/kernel/Text";
import { CoachPlanningApi } from "@cadencia/planning/CoachPlanningApi.api";
import type * as Domain from "@alchemy.run/domain";
import * as Model from "@alchemy.run/domain/Model";
import * as Effect from "effect/Effect";
import * as Option from "effect/Option";
import * as Schema from "effect/Schema";
import { PlanningInternals } from "./Hosting.ts";
import { actingAs } from "./Session.ts";

/** Every rejection Planning can answer the Coach with, as CoachPlanningApi's commands declare them. */
type PlanningRejection = InstanceType<Domain.Api.RejectionsOf<typeof CoachPlanningApi>>;

/**
 * Each Planning rejection in the coach's words. This is the anti-corruption
 * layer between the two models: Coach never sees Planning's rejection classes.
 * Keyed by the rejections Planning declares, so a new one fails to compile
 * here until it has a translation.
 */
const REASONS: { readonly [Tag in PlanningRejection["_tag"]]: RefusalReason } = {
  PlanNotActive: "planNotActive",
  DayNotPlanned: "dayNotPlanned",
  AvailabilityExceeded: "availabilityExceeded",
  IntensityAfterHardTraining: "intensityAfterHardTraining",
  HardensPlannedSession: "hardensPlan",
  PurposeMismatch: "purposeMismatch",
  InvalidPlan: "invalidPlan",
  PlanAlreadyExists: "planAlreadyExists",
  ImplausibleToday: "implausibleToday",
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

const accepted: { readonly answer: PlanAnswer } = { answer: { _tag: "Accepted" } };

const isPlanningRejection = (error: { readonly _tag: string }): error is PlanningRejection => error._tag in REASONS;

/**
 * Planning's answer in the coach's words. A rejection is a refusal; anything
 * else (the in-process transport, a session) is a defect for the policy's
 * redelivery, not an answer.
 */
const answerOf = <A, E extends { readonly _tag: string }>(
  call: Effect.Effect<A, E>,
): Effect.Effect<{ readonly answer: PlanAnswer }> =>
  call.pipe(
    Effect.as(accepted),
    Effect.catch((error) =>
      isPlanningRejection(error)
        ? Effect.succeed({
            answer: { _tag: "Refused", refusal: { reason: REASONS[error._tag], detail: detailOf(error) } },
          } as const)
        : Effect.die(error),
    ),
  );

/**
 * The Coach's `Planner`, answered by the Planning model in this process. Each
 * call acts as the athlete the Coach acts for, so Planning's own rules check
 * that the plan is theirs. A client is built per call: Workers forbid sharing
 * I/O across requests. Each request's id is the command's id, so a policy that
 * runs again gets the same answer instead of acting twice.
 */
export const PlanningPlanner = Planner.toLayer(
  Effect.gen(function* () {
    const internals = yield* PlanningInternals;
    const asAthlete = <A, E>(
      athleteId: AthleteId,
      call: (planning: Effect.Success<typeof CoachPlanningApi.clientInProcess>) => Effect.Effect<A, E>,
    ) =>
      CoachPlanningApi.clientInProcess.pipe(
        Effect.flatMap(call),
        Effect.provide(actingAs(athlete(athleteId))),
        Effect.provideService(Model.Internals, internals),
        Effect.scoped,
      );
    return {
      concretizeSession: ({ requestId, athleteId, planId, day, workout, evidence }) =>
        answerOf(
          asAthlete(athleteId, (planning) =>
            planning.ConcretizeSession(planId, { day, workout, evidence }, { commandId: requestId }),
          ),
        ),
      reviseWeek: ({ requestId, athleteId, planId, limits, today }) =>
        answerOf(
          asAthlete(athleteId, (planning) => planning.ReviseWeek(planId, { limits, today }, { commandId: requestId })),
        ),
      // The plan's objective is the one agreed in the consultation; the draft's rationale explains the
      // draft to the athlete and stays with the consultation.
      createPlan: ({ requestId, athleteId, planId, draft }) =>
        answerOf(
          asAthlete(athleteId, (planning) =>
            planning.CreatePlan(
            planId,
            {
              title: draft.title,
              goal: draft.goal,
              objective: draft.objective,
              startDay: draft.startDay,
              endDay: draft.endDay,
              phases: draft.phases,
              longRideWeekday: draft.longRideWeekday,
              event: draft.event ? { ...draft.event, objective: draft.objective } : null,
              sessions: draft.sessions,
            },
              { commandId: requestId },
            ),
          ),
        ),
    };
  }),
);
