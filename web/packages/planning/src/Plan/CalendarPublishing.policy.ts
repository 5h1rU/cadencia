import { system } from "@cadencia/identity/Actor";
import { ownerOf } from "@cadencia/identity/Athlete.id";
import { CurrentActor } from "@cadencia/identity/CurrentActor.context";
import * as Domain from "@alchemy.run/domain";
import * as Effect from "effect/Effect";
import * as Schedule from "effect/Schedule";
import { Calendar, CalendarUnavailable } from "./Calendar.external.ts";
import { SessionConcretized } from "./ConcretizeSession.command.ts";
import { PlanCreated } from "./CreatePlan.command.ts";
import { SessionMoved } from "./MoveSession.command.ts";
import { Plan } from "./Plan.aggregate.ts";
import type { PlannedSession } from "./PlannedSession.ts";
import { RecordCalendarFailure } from "./RecordCalendarFailure.command.ts";
import { RecordCalendarPublication } from "./RecordCalendarPublication.command.ts";
import { PlanRetired } from "./RetirePlan.command.ts";
import { WeekRevised } from "./ReviseWeek.command.ts";

/**
 * Whenever the plan's sessions change, mirror them on the Intervals calendar.
 * Every session has a deterministic `external_id`, so a policy that runs again
 * updates the same event instead of adding another.
 *
 * A refusal (the athlete disconnected Intervals, or Intervals won't take the
 * session) is recorded on the plan, so the athlete sees it and the plan's
 * later changes still go out. An outage is retried here, then redelivered.
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
      const athleteId = ownerOf(source.id);
      const record = (command: RecordCalendarPublication | RecordCalendarFailure) =>
        plans.send(source, command).pipe(Effect.provideService(CurrentActor, system("CalendarPublishing")));
      const publish = Effect.fn(function* (session: PlannedSession) {
        if (session.status === "skipped") {
          yield* calendar.withdrawSession({ athleteId, externalId: session.externalId });
          return;
        }
        const { published } = yield* calendar.publishSession({ athleteId, session });
        // Only a publication the calendar confirms is recorded; anything else is tried again.
        if (!published) return yield* new CalendarUnavailable();
        yield* record(new RecordCalendarPublication({ published: session }));
      });
      const publishOrRecord = (session: PlannedSession) =>
        publish(session).pipe(
          Effect.catchTag("CalendarRefused", ({ problem }) =>
            record(new RecordCalendarFailure({ sessionId: session.sessionId, problem })),
          ),
        );
      const run = Effect.gen(function* () {
        switch (event._tag) {
          case "PlanCreated":
          case "WeekRevised":
            yield* Effect.forEach(event.sessions, publishOrRecord, { discard: true });
            return;
          case "SessionConcretized":
          case "SessionMoved":
            yield* publishOrRecord(event.session);
            return;
          case "PlanRetired":
            // A retired plan has nothing left to show the athlete: a refused withdrawal is let go.
            yield* Effect.forEach(
              event.withdrawn,
              (externalId) =>
                calendar.withdrawSession({ athleteId, externalId }).pipe(Effect.catchTag("CalendarRefused", () => Effect.void)),
              { discard: true },
            );
            return;
        }
      });
      // An outage is a defect for the platform to redeliver, after the retries below.
      yield* run.pipe(Effect.catchTag("CalendarUnavailable", (e) => Effect.die(e)));
    });
  }),
  { retry: Schedule.exponential("2 seconds").pipe(Schedule.upTo({ times: 4 })) },
);
