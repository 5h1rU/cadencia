import { AthleteId, ownerOf } from "@cadencia/identity/Athlete.id";
import { CurrentActor } from "@cadencia/identity/CurrentActor.context";
import { mustBeSystem, mustOwn } from "@cadencia/identity/owns";
import { Day, daysBetween } from "@cadencia/kernel/Calendar/Day";
import { Weekday } from "@cadencia/kernel/Calendar/Week";
import { PlanId } from "@cadencia/kernel/Plan.id";
import { Paragraph, Title } from "@cadencia/kernel/Text";
import type { DayLimit } from "@cadencia/kernel/Training/DayLimit";
import { GoalKind } from "@cadencia/kernel/Training/Goal";
import { Phase } from "@cadencia/kernel/Training/Phase";
import { Minutes } from "@cadencia/kernel/Training/Units";
import { totalMinutes } from "@cadencia/kernel/Training/Workout";
import * as Domain from "@alchemy.run/domain";
import type * as DateTime from "effect/DateTime";
import * as Effect from "effect/Effect";
import * as Schema from "effect/Schema";
import { inputOf } from "../inputOf.ts";
import {
  AvailabilityExceeded,
  ConcretizeSession,
  DayNotPlanned,
  HardensPlannedSession,
  IntensityAfterHardTraining,
  PurposeMismatch,
  SessionConcretized,
} from "./ConcretizeSession.command.ts";
import {
  CreatePlan,
  type CreatePlan as CreatePlanCommand,
  InvalidPlan,
  PlanAlreadyExists,
  PlanCreated,
} from "./CreatePlan.command.ts";
import { DayOutsidePlan } from "./DayOutsidePlan.rejection.ts";
import { DayRequirement } from "./DayRequirement.ts";
import { GoalEvent } from "./GoalEvent.ts";
import { ImplausibleToday } from "./ImplausibleToday.rejection.ts";
import { DayTaken, MoveSession, SessionMoved, SessionNotFound, SessionNotMovable } from "./MoveSession.command.ts";
import { isAsPublished, isOwnedByCadencia, type PlannedSession, PlannedSession as PlannedSessionSchema } from "./PlannedSession.ts";
import { PlanNotActive } from "./PlanNotActive.rejection.ts";
import { isSoftened, problemWith } from "./PrescriptionRules.ts";
import { RecordCalendarFailure, SessionPublicationFailed } from "./RecordCalendarFailure.command.ts";
import { RecordCalendarPublication, SessionPublished } from "./RecordCalendarPublication.command.ts";
import { DayRequirementRecorded, RecordDayRequirement } from "./RecordDayRequirement.command.ts";
import {
  RecordExternalChange,
  SessionChangedInIntervals,
  SessionRemovedInIntervals,
} from "./RecordExternalChange.command.ts";
import { PlanRetired, RetirePlan } from "./RetirePlan.command.ts";
import { ReviseWeek, WeekRevised } from "./ReviseWeek.command.ts";
import { externalIdFor, type SessionId, SessionId as SessionIdSchema } from "./Session.id.ts";
import { isPlausibleToday } from "./Today.ts";

/** A plan has at most one session per day, so the day it was planned on names the session. */
const SessionIdOf = (day: Day) => SessionIdSchema.make(day);

const Active = Schema.TaggedStruct("Active", {
  athleteId: AthleteId,
  title: Title,
  goal: GoalKind,
  objective: Schema.NullOr(Paragraph),
  startDay: Day,
  endDay: Day,
  phases: Schema.Array(Phase),
  longRideWeekday: Weekday,
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

/**
 * The athlete's local day, as their client sends it, can't be checked against
 * a time zone the domain doesn't have; it must at least be plausible. A system
 * actor has no local day to send, so it is trusted.
 */
const mustBePlausibleToday = Effect.fn(function* (today: Day, now: DateTime.Utc) {
  const actor = yield* CurrentActor;
  if (actor._tag === "Athlete" && !isPlausibleToday(today, now)) return yield* new ImplausibleToday({ today });
});

const withinPlan = (plan: Active, day: Day) => day >= plan.startDay && day <= plan.endDay;

const replaceSessions = (plan: PlanState, changed: ReadonlyArray<PlannedSession>): PlanState => {
  if (plan._tag !== "Active") return plan;
  const byId = new Map(changed.map((s) => [s.sessionId, s]));
  return { ...plan, sessions: plan.sessions.map((s) => byId.get(s.sessionId) ?? s) };
};

const setStatus = (plan: PlanState, sessionId: SessionId, status: PlannedSession["status"]): PlanState => {
  if (plan._tag !== "Active") return plan;
  return {
    ...plan,
    sessions: plan.sessions.map((s) => (s.sessionId === sessionId ? { ...s, status } : s)),
  };
};

/**
 * A session within one day's limit, or `null` when the limit leaves it as it
 * is. A limit only removes riding: an unavailable day is skipped, and a
 * shorter day trims the session, keeping its workout only if it still fits.
 */
const limitedTo = (session: PlannedSession, limit: Omit<DayLimit, "day">): PlannedSession | null => {
  if (limit.unavailable) return { ...session, status: "skipped", targetMinutes: Minutes.make(0), workout: null };
  if (limit.maxMinutes === null || limit.maxMinutes >= session.targetMinutes) return null;
  const workoutFits = session.workout !== null && totalMinutes(session.workout) <= limit.maxMinutes + 0.1;
  return {
    ...session,
    targetMinutes: limit.maxMinutes,
    workout: workoutFits ? session.workout : null,
    status: workoutFits ? session.status : "provisional",
  };
};

/**
 * One limit per day, the strictest of those given for it: a day any limit
 * makes unavailable stays unavailable, and otherwise the shortest cap wins.
 * A later limit can't undo an earlier one.
 */
const strictestPerDay = (limits: ReadonlyArray<DayLimit>): Array<DayLimit> => {
  const byDay = new Map<Day, DayLimit>();
  for (const limit of limits) {
    const seen = byDay.get(limit.day);
    const caps = [seen?.maxMinutes, limit.maxMinutes].filter((m): m is Minutes => m != null);
    byDay.set(
      limit.day,
      seen === undefined
        ? limit
        : {
            day: limit.day,
            unavailable: seen.unavailable || limit.unavailable,
            maxMinutes: caps.length === 0 ? null : Minutes.make(Math.min(...caps)),
          },
    );
  }
  return [...byDay.values()];
};

/** Apply day limits to the plan's sessions from `today` on. */
const sessionsWithin = (plan: Active, limits: ReadonlyArray<DayLimit>, today: Day): Array<PlannedSession> =>
  strictestPerDay(limits).flatMap((limit) => {
    if (limit.day < today) return [];
    const session = plan.sessions.find((s) => s.day === limit.day && isOwnedByCadencia(s));
    if (!session || session.status === "skipped") return [];
    return limitedTo(session, limit) ?? [];
  });

/** Why a draft can't become a plan, if it can't. */
const invalidReason = (cmd: CreatePlanCommand): InvalidPlan["reason"] | null => {
  if (cmd.startDay > cmd.endDay) return "endsBeforeStart";
  const days = cmd.sessions.map((s) => s.day);
  if (new Set(days).size !== days.length) return "twoSessionsOneDay";
  if (days.some((day) => day < cmd.startDay || day > cmd.endDay)) return "sessionOutsideDates";
  if (cmd.sessions.length === 0) return "noSessions";
  const weeks = Math.floor(daysBetween(cmd.startDay, cmd.endDay) / 7) + 1;
  let next = 1;
  for (const phase of cmd.phases) {
    if (phase.startWeek !== next || phase.endWeek > weeks) return "phasesDontCoverPlan";
    next = phase.endWeek + 1;
  }
  if (next !== weeks + 1) return "phasesDontCoverPlan";
  if (cmd.event !== null && (cmd.event.day < cmd.startDay || cmd.event.day > cmd.endDay)) return "eventOutsidePlan";
  if (cmd.goal === "event" && cmd.event === null) return "eventGoalWithoutEvent";
  return null;
};

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
    RecordCalendarFailure,
    RecordExternalChange,
    RetirePlan,
  ],
  decide: {
    CreatePlan: Effect.fn(function* (plan, cmd, { id }) {
      const athleteId = ownerOf(id);
      yield* mustOwn(athleteId);
      if (plan._tag !== "Unplanned") return yield* new PlanAlreadyExists();
      const reason = invalidReason(cmd);
      if (reason !== null) return yield* new InvalidPlan({ reason });
      const sessions = cmd.sessions.map((draft): PlannedSession => {
        const sessionId = SessionIdOf(draft.day);
        return { ...draft, sessionId, status: "provisional", workout: null, externalId: externalIdFor(id, sessionId) };
      });
      return [new PlanCreated({ athleteId, ...inputOf(cmd), sessions })];
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
            return yield* new PurposeMismatch({ day: cmd.day, problem: problem.problem });
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

    ReviseWeek: Effect.fn(function* (state, cmd, { now }) {
      const plan = yield* activeFor(state);
      yield* mustBePlausibleToday(cmd.today, now);
      const changed = sessionsWithin(plan, cmd.limits, cmd.today);
      return changed.length === 0 ? [] : [new WeekRevised({ sessions: changed })];
    }),

    MoveSession: Effect.fn(function* (state, cmd) {
      const plan = yield* activeFor(state);
      const session = plan.sessions.find((s) => s.sessionId === cmd.sessionId);
      if (!session) return yield* new SessionNotFound({ sessionId: cmd.sessionId });
      if (!isOwnedByCadencia(session) || session.status === "skipped") {
        return yield* new SessionNotMovable({ sessionId: session.sessionId, status: session.status });
      }
      if (!withinPlan(plan, cmd.toDay)) {
        return yield* new DayOutsidePlan({ day: cmd.toDay, startDay: plan.startDay, endDay: plan.endDay });
      }
      if (session.day === cmd.toDay) return [];
      // A skipped session still holds its day: the day names one session.
      if (plan.sessions.some((s) => s.day === cmd.toDay && s.status !== "removedInIntervals")) {
        return yield* new DayTaken({ day: cmd.toDay });
      }
      const moved: PlannedSession = { ...session, day: cmd.toDay, status: session.workout ? "concrete" : "provisional" };
      // The athlete's requirement for the new day holds for whatever session lands there.
      const requirement = plan.requirements.find((r) => r.day === cmd.toDay);
      const fitted = requirement === undefined ? null : limitedTo(moved, { ...requirement, unavailable: false });
      return [new SessionMoved({ session: fitted ?? moved, fromDay: session.day })];
    }),

    RecordDayRequirement: Effect.fn(function* (state, cmd) {
      const plan = yield* activeFor(state);
      if (!withinPlan(plan, cmd.day)) {
        return yield* new DayOutsidePlan({ day: cmd.day, startDay: plan.startDay, endDay: plan.endDay });
      }
      const trimmed = sessionsWithin(plan, [{ day: cmd.day, maxMinutes: cmd.maxMinutes, unavailable: false }], cmd.day);
      return [
        new DayRequirementRecorded({ requirement: inputOf(cmd) }),
        ...(trimmed.length === 0 ? [] : [new WeekRevised({ sessions: trimmed })]),
      ];
    }),

    RecordCalendarPublication: (plan, cmd) => {
      if (plan._tag !== "Active") return [];
      const session = plan.sessions.find((s) => s.sessionId === cmd.published.sessionId);
      if (!session || !isOwnedByCadencia(session) || !isAsPublished(session, cmd.published)) return [];
      if (session.status === "published" || session.status === "skipped") return [];
      return [new SessionPublished({ sessionId: session.sessionId, externalId: session.externalId })];
    },

    RecordCalendarFailure: (plan, cmd) => {
      if (plan._tag !== "Active") return [];
      const session = plan.sessions.find((s) => s.sessionId === cmd.sessionId);
      return session ? [new SessionPublicationFailed(inputOf(cmd))] : [];
    },

    RecordExternalChange: Effect.fn(function* (plan, cmd) {
      yield* mustBeSystem("IntervalsSync");
      if (plan._tag !== "Active") return [];
      const session = plan.sessions.find((s) => s.externalId === cmd.externalId);
      // The sync compared another version of the session (it was moved or trimmed since): stale.
      if (!session || !isAsPublished(session, cmd.observed)) return [];
      // Only what Intervals shows as Cadencia published it can have been changed there: a session
      // being published again was compared against a stale copy. One the athlete changed can still go.
      const removable = session.status === "published" || session.status === "changedInIntervals";
      if (session.status !== "published" && !(cmd.change === "removed" && removable)) return [];
      return cmd.change === "removed"
        ? [new SessionRemovedInIntervals({ sessionId: session.sessionId })]
        : [new SessionChangedInIntervals({ sessionId: session.sessionId })];
    }),

    RetirePlan: Effect.fn(function* (state, cmd, { now }) {
      const plan = yield* activeFor(state);
      yield* mustBePlausibleToday(cmd.today, now);
      const withdrawn = plan.sessions
        .filter((s) => s.day >= cmd.today && isOwnedByCadencia(s) && s.status !== "skipped")
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
      objective: e.objective,
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
    SessionPublicationFailed: (s) => s,
    SessionChangedInIntervals: (s, e) => setStatus(s, e.sessionId, "changedInIntervals"),
    SessionRemovedInIntervals: (s, e) => setStatus(s, e.sessionId, "removedInIntervals"),
    PlanRetired: (s) => (s._tag === "Active" ? { _tag: "Retired" as const, athleteId: s.athleteId } : s),
  },
}) {}
