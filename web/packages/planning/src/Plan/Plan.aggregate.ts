import { AthleteId } from "@cadencia/kernel/Athlete.id";
import { Day } from "@cadencia/kernel/Day";
import { inputOf, mustOwn } from "@cadencia/kernel/owns";
import { totalMinutes } from "@cadencia/kernel/Workout";
import * as Domain from "@alchemy.run/domain";
import * as DateTime from "effect/DateTime";
import * as Effect from "effect/Effect";
import * as Schema from "effect/Schema";
import { AvailabilityExceeded } from "./AvailabilityExceeded.rejection.ts";
import {
  ConcretizeSession,
  DayNotPlanned,
  IntensityAfterHardTraining,
  PurposeMismatch,
  SessionConcretized,
} from "./ConcretizeSession.command.ts";
import { CreatePlan, InvalidPlan, PlanAlreadyExists, PlanCreated } from "./CreatePlan.command.ts";
import { DayOutsidePlan } from "./DayOutsidePlan.rejection.ts";
import { HardensPlannedSession } from "./HardensPlannedSession.rejection.ts";
import { DayTaken, MoveSession, SessionMoved } from "./MoveSession.command.ts";
import { athleteOfPlan, PlanId } from "./Plan.id.ts";
import { PlanNotActive } from "./PlanNotActive.rejection.ts";
import {
  DayRequirement,
  externalIdFor,
  GoalEvent,
  GoalKind,
  Phase,
  type PlannedSession,
  PlannedSession as PlannedSessionSchema,
} from "./PlanShape.ts";
import { isSoftened, problemWith } from "./PrescriptionRules.ts";
import { RecordCalendarPublication, SessionPublished } from "./RecordCalendarPublication.command.ts";
import { DayRequirementRecorded, RecordDayRequirement } from "./RecordDayRequirement.command.ts";
import {
  RecordExternalChange,
  SessionChangedInIntervals,
  SessionRemovedInIntervals,
} from "./RecordExternalChange.command.ts";
import { PlanRetired, RetirePlan } from "./RetirePlan.command.ts";
import { ReviseWeek, WeekRevised } from "./ReviseWeek.command.ts";
import { SessionNotFound } from "./SessionNotFound.rejection.ts";

const Active = Schema.TaggedStruct("Active", {
  athleteId: AthleteId,
  title: Schema.String,
  goal: GoalKind,
  startDay: Day,
  endDay: Day,
  phases: Schema.Array(Phase),
  longRideWeekday: Schema.Int,
  event: Schema.NullOr(GoalEvent),
  sessions: Schema.Array(PlannedSessionSchema),
  requirements: Schema.Array(DayRequirement),
});
type Active = typeof Active.Type;

export const PlanState = Schema.Union([
  Schema.TaggedStruct("Unplanned", {}),
  Active,
  Schema.TaggedStruct("Retired", { athleteId: AthleteId }),
]);
export type PlanState = typeof PlanState.Type;

/** The active plan, if the current actor may act on it. Every athlete command starts here. */
const activeFor = Effect.fn(function* (plan: PlanState) {
  if (plan._tag === "Unplanned") return yield* new PlanNotActive();
  yield* mustOwn(plan.athleteId);
  if (plan._tag !== "Active") return yield* new PlanNotActive();
  return plan;
});

const withinPlan = (plan: Active, day: Day) => day >= plan.startDay && day <= plan.endDay;

const replaceSessions = (plan: PlanState, changed: ReadonlyArray<PlannedSession>): PlanState => {
  if (plan._tag !== "Active") return plan;
  const byId = new Map(changed.map((s) => [s.sessionId, s]));
  return { ...plan, sessions: plan.sessions.map((s) => byId.get(s.sessionId) ?? s) };
};

const setStatus = (plan: PlanState, sessionId: string, status: PlannedSession["status"]): PlanState => {
  if (plan._tag !== "Active") return plan;
  return {
    ...plan,
    sessions: plan.sessions.map((s) => (s.sessionId === sessionId ? { ...s, status } : s)),
  };
};

/** Sessions the athlete has taken over in Intervals stay as they are. */
const isOwnedByCadencia = (session: PlannedSession) =>
  session.status !== "changedInIntervals" && session.status !== "removedInIntervals";

/**
 * A training plan: its intent (goal, phases, purpose of each session) and the
 * rules every change must respect, whoever proposes it. The Intervals calendar
 * is its projection.
 */
export class Plan extends Domain.Aggregate("Plan", {
  id: PlanId,
  state: PlanState,
  initial: { _tag: "Unplanned" },
  commands: [
    CreatePlan,
    ConcretizeSession,
    ReviseWeek,
    MoveSession,
    RecordDayRequirement,
    RecordCalendarPublication,
    RecordExternalChange,
    RetirePlan,
  ],
  decide: {
    CreatePlan: Effect.fn(function* (plan, cmd, { id }) {
      yield* mustOwn(cmd.athleteId);
      if (athleteOfPlan(id) !== cmd.athleteId) {
        return yield* new InvalidPlan({ reason: "The plan id must start with the athlete's id." });
      }
      if (plan._tag !== "Unplanned") return yield* new PlanAlreadyExists();
      if (cmd.startDay > cmd.endDay) {
        return yield* new InvalidPlan({ reason: "The plan ends before it starts." });
      }
      const days = cmd.sessions.map((s) => s.day);
      if (new Set(days).size !== days.length) {
        return yield* new InvalidPlan({ reason: "A plan has at most one session per day." });
      }
      if (days.some((day) => day < cmd.startDay || day > cmd.endDay)) {
        return yield* new InvalidPlan({ reason: "Every session must fall within the plan's dates." });
      }
      if (cmd.sessions.length === 0) {
        return yield* new InvalidPlan({ reason: "A plan needs at least one session." });
      }
      const sessions = cmd.sessions.map(
        (draft): PlannedSession => ({
          ...draft,
          sessionId: draft.day,
          status: "provisional",
          workout: null,
          externalId: externalIdFor(id, draft.day),
        }),
      );
      return [
        new PlanCreated({
          athleteId: cmd.athleteId,
          title: cmd.title,
          goal: cmd.goal,
          startDay: cmd.startDay,
          endDay: cmd.endDay,
          phases: cmd.phases,
          longRideWeekday: cmd.longRideWeekday,
          event: cmd.event,
          sessions,
        }),
      ];
    }),

    ConcretizeSession: Effect.fn(function* (state, cmd) {
      const plan = yield* activeFor(state);
      const session = plan.sessions.find((s) => s.day === cmd.day && isOwnedByCadencia(s));
      if (!session) return yield* new DayNotPlanned({ day: cmd.day });
      const problem = problemWith({
        session,
        workout: cmd.workout,
        evidence: cmd.evidence,
        requirement: plan.requirements.find((r) => r.day === cmd.day),
        goalEvent: plan.event,
      });
      if (problem) {
        switch (problem._tag) {
          case "AvailabilityExceeded":
            return yield* new AvailabilityExceeded({ day: cmd.day, ...problem });
          case "IntensityAfterHardTraining":
            return yield* new IntensityAfterHardTraining({
              day: cmd.day,
              proposed: cmd.workout.kind,
              peakIntensity: problem.peakIntensity,
            });
          case "HardensPlannedSession":
            return yield* new HardensPlannedSession({
              day: cmd.day,
              planned: session.kind,
              proposed: cmd.workout.kind,
              peakIntensity: problem.peakIntensity,
            });
          case "PurposeMismatch":
            return yield* new PurposeMismatch({ day: cmd.day, reason: problem.reason });
        }
      }
      return [
        new SessionConcretized({
          session: { ...session, status: "concrete", workout: cmd.workout },
          softened: isSoftened(session, cmd.workout),
          fingerprint: cmd.evidence.fingerprint,
        }),
      ];
    }),

    ReviseWeek: Effect.fn(function* (state, cmd) {
      const plan = yield* activeFor(state);
      const changed: Array<PlannedSession> = [];
      for (const limit of cmd.limits) {
        const session = plan.sessions.find((s) => s.day === limit.day && isOwnedByCadencia(s));
        if (!session || session.status === "skipped") continue;
        if (limit.unavailable) {
          changed.push({ ...session, status: "skipped", targetMinutes: 0, workout: null });
        } else if (limit.maxMinutes !== null && limit.maxMinutes < session.targetMinutes) {
          const workoutFits = session.workout !== null && totalMinutes(session.workout) <= limit.maxMinutes + 0.1;
          changed.push({
            ...session,
            targetMinutes: limit.maxMinutes,
            workout: workoutFits ? session.workout : null,
            status: workoutFits ? session.status : "provisional",
          });
        }
      }
      return changed.length === 0 ? [] : [new WeekRevised({ sessions: changed })];
    }),

    MoveSession: Effect.fn(function* (state, cmd) {
      const plan = yield* activeFor(state);
      const session = plan.sessions.find((s) => s.sessionId === cmd.sessionId);
      if (!session) return yield* new SessionNotFound({ sessionId: cmd.sessionId });
      if (!withinPlan(plan, cmd.toDay)) {
        return yield* new DayOutsidePlan({ day: cmd.toDay, startDay: plan.startDay, endDay: plan.endDay });
      }
      if (session.day === cmd.toDay) return [];
      if (plan.sessions.some((s) => s.day === cmd.toDay && s.status !== "skipped" && s.status !== "removedInIntervals")) {
        return yield* new DayTaken({ day: cmd.toDay });
      }
      return [
        new SessionMoved({
          session: { ...session, day: cmd.toDay, status: session.workout ? "concrete" : "provisional" },
          fromDay: session.day,
        }),
      ];
    }),

    RecordDayRequirement: Effect.fn(function* (state, cmd) {
      const plan = yield* activeFor(state);
      if (!withinPlan(plan, cmd.day)) {
        return yield* new DayOutsidePlan({ day: cmd.day, startDay: plan.startDay, endDay: plan.endDay });
      }
      return [new DayRequirementRecorded({ requirement: inputOf(cmd) })];
    }),

    RecordCalendarPublication: (plan, cmd) => {
      if (plan._tag !== "Active") return [];
      const session = plan.sessions.find((s) => s.sessionId === cmd.sessionId);
      if (!session || session.externalId !== cmd.externalId || !isOwnedByCadencia(session)) return [];
      if (session.status === "published" || session.status === "skipped") return [];
      return [new SessionPublished({ sessionId: session.sessionId, externalId: session.externalId })];
    },

    RecordExternalChange: (plan, cmd) => {
      if (plan._tag !== "Active") return [];
      const session = plan.sessions.find((s) => s.externalId === cmd.externalId);
      if (!session) return [];
      if (cmd.change === "removed") {
        return session.status === "removedInIntervals"
          ? []
          : [new SessionRemovedInIntervals({ sessionId: session.sessionId })];
      }
      return session.status === "changedInIntervals"
        ? []
        : [new SessionChangedInIntervals({ sessionId: session.sessionId })];
    },

    RetirePlan: Effect.fn(function* (state, _cmd, { now }) {
      const plan = yield* activeFor(state);
      const today = DateTime.formatIsoDate(now);
      const withdrawn = plan.sessions
        .filter((s) => s.day >= today && isOwnedByCadencia(s) && s.status !== "skipped")
        .map((s) => s.externalId);
      return [new PlanRetired({ withdrawn })];
    }),
  },

  evolve: {
    PlanCreated: (_, e) => ({
      _tag: "Active" as const,
      athleteId: e.athleteId,
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
    SessionConcretized: (s, e) => replaceSessions(s, [e.session]),
    WeekRevised: (s, e) => replaceSessions(s, e.sessions),
    SessionMoved: (s, e) => replaceSessions(s, [e.session]),
    DayRequirementRecorded: (s, e) =>
      s._tag === "Active"
        ? {
            ...s,
            requirements: [...s.requirements.filter((r) => r.day !== e.requirement.day), e.requirement],
          }
        : s,
    SessionPublished: (s, e) => setStatus(s, e.sessionId, "published"),
    SessionChangedInIntervals: (s, e) => setStatus(s, e.sessionId, "changedInIntervals"),
    SessionRemovedInIntervals: (s, e) => setStatus(s, e.sessionId, "removedInIntervals"),
    PlanRetired: (s) => (s._tag === "Active" ? { _tag: "Retired" as const, athleteId: s.athleteId } : s),
  },
}) {}
