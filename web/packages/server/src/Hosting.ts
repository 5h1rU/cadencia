import { Coach, CoachHandlers } from "@cadencia/coach/Coach.model";
import { Planning, PlanningHandlers } from "@cadencia/planning/Planning.model";
import * as Model from "@alchemy.run/domain/Model";
import * as Context from "effect/Context";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";

/*
 * Two models share this Worker. Each hosted model provides its internals under
 * one shared key, so the second one built hides the first. Every Api is built
 * over the internals of its own model: Planning's Apis over Planning's, the
 * Coach's over the Coach's.
 */

export class PlanningInternals extends Context.Service<PlanningInternals, Model.Internals["Service"]>()(
  "Cadencia/PlanningInternals",
) {}

export class CoachInternals extends Context.Service<CoachInternals, Model.Internals["Service"]>()(
  "Cadencia/CoachInternals",
) {}

type Internals = Model.Internals["Service"];

/** Planning, hosted, with its internals kept apart. Requires the `Calendar` external system and a platform. */
export const PlanningHosted = Layer.effect(PlanningInternals, Effect.gen(function* () {
  return yield* Model.Internals;
})).pipe(Layer.provideMerge(Planning.layer(PlanningHandlers)));

/** The Coach, hosted, with its internals kept apart. Requires the `Planner` external system and a platform. */
export const CoachHosted = Layer.effect(CoachInternals, Effect.gen(function* () {
  return yield* Model.Internals;
})).pipe(Layer.provideMerge(Coach.layer(CoachHandlers)));

/** Run something built over Planning's Apis. */
export const overPlanning = <A, E, R>(effect: Effect.Effect<A, E, R>) =>
  Effect.gen(function* () {
    const internals: Internals = yield* PlanningInternals;
    return yield* Effect.provideService(effect, Model.Internals, internals);
  });

/** Run something built over the Coach's Apis. */
export const overCoach = <A, E, R>(effect: Effect.Effect<A, E, R>) =>
  Effect.gen(function* () {
    const internals: Internals = yield* CoachInternals;
    return yield* Effect.provideService(effect, Model.Internals, internals);
  });

/** A Layer built over the Coach's Apis. */
export const layerOverCoach = <A, E, R>(layer: Layer.Layer<A, E, R>) =>
  Layer.unwrap(
    Effect.gen(function* () {
      const internals: Internals = yield* CoachInternals;
      return Layer.provide(layer, Layer.succeed(Model.Internals, internals));
    }),
  );

/** A Layer built over Planning's Apis. */
export const layerOverPlanning = <A, E, R>(layer: Layer.Layer<A, E, R>) =>
  Layer.unwrap(
    Effect.gen(function* () {
      const internals: Internals = yield* PlanningInternals;
      return Layer.provide(layer, Layer.succeed(Model.Internals, internals));
    }),
  );
