import { AthleteId } from "@cadencia/kernel/Athlete.id";
import { Day } from "@cadencia/kernel/Day";
import { NotYours } from "@cadencia/kernel/NotYours.rejection";
import { mustOwn } from "@cadencia/kernel/owns";
import { Session } from "@cadencia/kernel/Session.middleware";
import * as Domain from "@alchemy.run/domain";
import * as Effect from "effect/Effect";
import * as Schema from "effect/Schema";
import { Plan } from "./Plan.aggregate.ts";
import { athleteOfPlan } from "./Plan.id.ts";
import { DayRequirement, GoalEvent, GoalKind, Phase, type PlannedSession, PlannedSession as Session_ } from "./PlanShape.ts";

const CurrentPlanState = Schema.Struct({
  planId: Schema.NullOr(Schema.String),
  status: Schema.Literals(["none", "active", "retired"]),
  title: Schema.String,
  goal: Schema.NullOr(GoalKind),
  startDay: Schema.NullOr(Day),
  endDay: Schema.NullOr(Day),
  phases: Schema.Array(Phase),
  longRideWeekday: Schema.NullOr(Schema.Int),
  event: Schema.NullOr(GoalEvent),
  sessions: Schema.Array(Session_),
  requirements: Schema.Array(DayRequirement),
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
  keyOf: { Plan: ({ source }) => athleteOfPlan(source.id) },
  state: CurrentPlanState,
  initial: {
    planId: null,
    status: "none",
    title: "",
    goal: null,
    startDay: null,
    endDay: null,
    phases: [],
    longRideWeekday: null,
    event: null,
    sessions: [],
    requirements: [],
  },
  evolve: {
    PlanCreated: (_, e, { source }) => ({
      planId: source.id,
      status: "active" as const,
      title: e.title,
      goal: e.goal,
      startDay: e.startDay,
      endDay: e.endDay,
      phases: e.phases,
      longRideWeekday: e.longRideWeekday,
      event: e.event,
      sessions: e.sessions,
      requirements: [],
    }),
    SessionConcretized: forShownPlan((v, e) => replace(v, [e.session])),
    WeekRevised: forShownPlan((v, e) => replace(v, e.sessions)),
    SessionMoved: forShownPlan((v, e) => replace(v, [e.session])),
    DayRequirementRecorded: forShownPlan((v, e) => ({
      ...v,
      requirements: [...v.requirements.filter((r) => r.day !== e.requirement.day), e.requirement],
    })),
    SessionPublished: withStatus("published"),
    SessionChangedInIntervals: withStatus("changedInIntervals"),
    SessionRemovedInIntervals: withStatus("removedInIntervals"),
    PlanRetired: forShownPlan((v) => ({ ...v, status: "retired" as const })),
  },
  // Keyed by athlete, so the key alone decides who may read it.
  validate: Effect.fn(function* (request) {
    yield* mustOwn(request.key);
  }),
}) {}
