import { system } from "@cadencia/kernel/Actor";
import { CurrentActor } from "@cadencia/kernel/CurrentActor.context";
import * as Domain from "@alchemy.run/domain";
import * as Effect from "effect/Effect";
import { Calendar } from "./Calendar.external.ts";
import { SessionConcretized } from "./ConcretizeSession.command.ts";
import { PlanCreated } from "./CreatePlan.command.ts";
import { SessionMoved } from "./MoveSession.command.ts";
import { Plan } from "./Plan.aggregate.ts";
import { athleteOfPlan } from "./Plan.id.ts";
import type { PlannedSession } from "./PlanShape.ts";
import { RecordCalendarPublication } from "./RecordCalendarPublication.command.ts";
import { PlanRetired } from "./RetirePlan.command.ts";
import { WeekRevised } from "./ReviseWeek.command.ts";

/**
 * Whenever the plan's sessions change, mirror them on the Intervals calendar.
 * Every session has a deterministic `external_id`, so a policy that runs again
 * updates the same event instead of adding another.
 */
export class CalendarPublishing extends Domain.Policy("CalendarPublishing", {
  from: Plan,
  on: [PlanCreated, SessionConcretized, WeekRevised, SessionMoved, PlanRetired],
}) {}

export const CalendarPublishingLive = CalendarPublishing.toLayer(
  Effect.gen(function* () {
    const calendar = yield* Calendar;
    const plans = yield* Plan;
    return Effect.fn(function* ({ source, event }) {
      const athleteId = athleteOfPlan(source.id);
      const publish = Effect.fn(function* (session: PlannedSession) {
        if (session.status === "skipped") {
          yield* calendar.withdrawSession({ athleteId, externalId: session.externalId });
          return;
        }
        yield* calendar.publishSession({ athleteId, session });
        yield* plans
          .send(
            source,
            new RecordCalendarPublication({ sessionId: session.sessionId, externalId: session.externalId }),
          )
          .pipe(Effect.provideService(CurrentActor, system("CalendarPublishing")));
      });
      switch (event._tag) {
        case "PlanCreated":
          yield* Effect.forEach(event.sessions, publish, { discard: true });
          return;
        case "SessionConcretized":
        case "SessionMoved":
          yield* publish(event.session);
          return;
        case "WeekRevised":
          yield* Effect.forEach(event.sessions, publish, { discard: true });
          return;
        case "PlanRetired":
          yield* Effect.forEach(
            event.withdrawn,
            (externalId) => calendar.withdrawSession({ athleteId, externalId }),
            { discard: true },
          );
          return;
      }
    });
  }),
);
