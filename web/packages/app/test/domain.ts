import { athlete } from "@cadencia/identity/Actor";
import { Authenticated } from "@cadencia/identity/Authenticated.middleware";
import { CurrentActor } from "@cadencia/identity/CurrentActor.context";
import { Day } from "@cadencia/kernel/Calendar/Day";
import { Weekday } from "@cadencia/kernel/Calendar/Week";
import { EntityKey } from "@cadencia/kernel/EntityKey";
import { planIdFor } from "@cadencia/kernel/Plan.id";
import { Paragraph, Title } from "@cadencia/kernel/Text";
import { Phase } from "@cadencia/kernel/Training/Phase";
import { Minutes } from "@cadencia/kernel/Training/Units";
import { AthletePlanningApi } from "@cadencia/planning/AthletePlanningApi.api";
import { Calendar } from "@cadencia/planning/Plan/Calendar.external";
import { CreatePlan } from "@cadencia/planning/Plan/CreatePlan.command";
import { Plan } from "@cadencia/planning/Plan/Plan.aggregate";
import { Planning, PlanningHandlers } from "@cadencia/planning/Planning.model";
import * as Domain from "@alchemy.run/domain";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as Schema from "effect/Schema";
import { ana } from "./fixture.ts";

/** A calendar that accepts everything, in place of Intervals.icu. */
const AcceptingCalendar = Calendar.toLayer(
  Effect.succeed({
    publishSession: () => Effect.succeed({ published: true }),
    withdrawSession: () => Effect.succeed({ withdrawn: true }),
  }),
);

/** The real Planning model, its rules and its policies, in memory. */
const Hosted = Planning.layer(PlanningHandlers).pipe(Layer.provide(Layer.mergeAll(AcceptingCalendar, Domain.InMemory)));

/** Every call is Ana's: what the server's session does for a signed-in athlete. */
const AsAna = Layer.succeed(Authenticated, (effect) => Effect.provideService(effect, CurrentActor, athlete(ana)));

/**
 * The Api the app talks to, answered by the real Planning model in this
 * process: what the app sends is decided by the same aggregate as in production.
 */
export const PlanningInMemory = AthletePlanningApi.layerClientInProcess.pipe(Layer.provideMerge(Layer.merge(Hosted, AsAna)));

export const planId = planIdFor(ana, EntityKey.make("0b6f5a2e-1c3d-4e5f-8a9b-0c1d2e3f4a5b"));

const session = (day: string, kind: "endurance" | "threshold" | "longRide", minutes: number, title: string) => ({
  day: Day.make(day),
  kind,
  title: Title.make(title),
  targetMinutes: Minutes.make(minutes),
  purpose: Paragraph.make(title),
});

/** Ana's plan, created through the aggregate as the Coach creates it: Monday, Tuesday and Saturday of one week. */
export const createPlan = Effect.gen(function* () {
  const plans = yield* Plan;
  yield* plans
    .send(
      Plan.ref(planId),
      new CreatePlan({
        title: Title.make("Base block"),
        goal: "endurance",
        objective: null,
        startDay: Day.make("2026-11-09"),
        endDay: Day.make("2026-12-20"),
        phases: [Schema.decodeUnknownSync(Phase)({ focus: "base", startWeek: 1, endWeek: 6, summary: "Aerobic base" })],
        longRideWeekday: Weekday.make(7),
        event: null,
        sessions: [
          session("2026-11-09", "endurance", 60, "Easy endurance"),
          session("2026-11-10", "threshold", 75, "Threshold"),
          session("2026-11-14", "longRide", 180, "Long ride"),
        ],
      }),
    )
    .pipe(Effect.provideService(CurrentActor, athlete(ana)));
});
