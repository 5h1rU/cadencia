import { AthleteId, ownerOf } from "@cadencia/identity/Athlete.id";
import { NotYours } from "@cadencia/identity/NotYours.rejection";
import { mustOwn } from "@cadencia/identity/owns";
import { Session } from "@cadencia/identity/Session.middleware";
import { Day } from "@cadencia/kernel/Calendar/Day";
import { Weekday } from "@cadencia/kernel/Calendar/Week";
import { PlanId } from "@cadencia/kernel/Plan.id";
import { Paragraph, Title } from "@cadencia/kernel/Text";
import * as Domain from "@alchemy.run/domain";
import * as Effect from "effect/Effect";
import * as Schema from "effect/Schema";
import { CalendarProblem } from "./Calendar.external.ts";
import { Plan } from "./Plan.aggregate.ts";
import {
  DayRequirement,
  GoalEvent,
  GoalKind,
  Phase,
  type PlannedSession,
  PlannedSession as Session_,
} from "./PlanShape.ts";
import { SessionId } from "./Session.id.ts";

export const CurrentPlanState = Schema.Struct({
  planId: Schema.NullOr(PlanId),
  status: Schema.Literals(["none", "active", "retired"]),
  title: Schema.NullOr(Title),
  goal: Schema.NullOr(GoalKind),
  objective: Schema.NullOr(Paragraph),
  startDay: Schema.NullOr(Day),
  endDay: Schema.NullOr(Day),
  phases: Schema.Array(Phase),
  longRideWeekday: Schema.NullOr(Weekday),
  event: Schema.NullOr(GoalEvent),
  sessions: Schema.Array(Session_),
  requirements: Schema.Array(DayRequirement),
  /** Sessions the Intervals calendar refused, until one is published. */
  calendarProblems: Schema.Array(Schema.Struct({ sessionId: SessionId, problem: CalendarProblem })),
});
type CurrentPlanState = typeof CurrentPlanState.Type;

/** Apply a change only when it belongs to the plan this view shows. */
const forShownPlan =
  <E>(apply: (v: CurrentPlanState, e: E) => CurrentPlanState) =>
  (v: CurrentPlanState, e: E, ctx: { readonly source: { readonly id: string } }) =>
    v.planId === ctx.source.id ? apply(v, e) : v;

const replace = (v: CurrentPlanState, changed: ReadonlyArray<PlannedSession>): CurrentPlanState => {
  const byId = new Map(changed.map((s) => [s.sessionId, s]));
  return { ...v, sessions: v.sessions.map((s) => byId.get(s.sessionId) ?? s) };
};

const withStatus = (status: PlannedSession["status"]) =>
  forShownPlan<{ readonly sessionId: string }>((v, e) => ({
    ...v,
    sessions: v.sessions.map((s) => (s.sessionId === e.sessionId ? { ...s, status } : s)),
  }));

/**
 * The athlete's current plan: the most recently created one, with its weeks,
 * sessions and their state. The web and iOS watch it live.
 */
export class CurrentPlan extends Domain.View("CurrentPlan", {
  from: [Plan],
  key: AthleteId,
  middleware: [Session],
  rejects: [NotYours],
  keyOf: { Plan: ({ source }) => ownerOf(source.id) },
  state: CurrentPlanState,
  // Bump when the state or how it folds changes, so the view is rebuilt from the plan's events.
  version: 1,
  initial: {
    planId: null,
    status: "none",
    title: null,
    goal: null,
    objective: null,
    startDay: null,
    endDay: null,
    phases: [],
    longRideWeekday: null,
    event: null,
    sessions: [],
    requirements: [],
    calendarProblems: [],
  },
  evolve: {
    PlanCreated: (_, e, { source }) => ({
      planId: source.id,
      status: "active" as const,
      title: e.title,
      goal: e.goal,
      objective: e.objective,
      startDay: e.startDay,
      endDay: e.endDay,
      phases: e.phases,
      longRideWeekday: e.longRideWeekday,
      event: e.event,
      sessions: e.sessions,
      requirements: [],
      calendarProblems: [],
    }),
    SessionConcretized: forShownPlan((v, e) => replace(v, [e.session])),
    WeekRevised: forShownPlan((v, e) => replace(v, e.sessions)),
    SessionMoved: forShownPlan((v, e) => replace(v, [e.session])),
    DayRequirementRecorded: forShownPlan((v, e) => ({
      ...v,
      requirements: [...v.requirements.filter((r) => r.day !== e.requirement.day), e.requirement],
    })),
    SessionPublished: forShownPlan((v, e) =>
      withStatus("published")(
        { ...v, calendarProblems: v.calendarProblems.filter((p) => p.sessionId !== e.sessionId) },
        e,
        { source: { id: v.planId ?? "" } },
      ),
    ),
    SessionPublicationFailed: forShownPlan((v, e) => ({
      ...v,
      calendarProblems: [...v.calendarProblems.filter((p) => p.sessionId !== e.sessionId), e],
    })),
    SessionChangedInIntervals: withStatus("changedInIntervals"),
    SessionRemovedInIntervals: withStatus("removedInIntervals"),
    PlanRetired: forShownPlan((v) => ({ ...v, status: "retired" as const })),
  },
  // Keyed by athlete, so the key alone decides who may read it.
  validate: Effect.fn(function* (request) {
    yield* mustOwn(request.key);
  }),
}) {}
