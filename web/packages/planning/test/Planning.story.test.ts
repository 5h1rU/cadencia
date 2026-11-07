import { Fingerprint } from "@cadencia/athlete/Evidence";
import { system, system as systemActor } from "@cadencia/identity/Actor";
import type { Actor } from "@cadencia/identity/Actor";
import { AthleteId } from "@cadencia/identity/Athlete.id";
import { CurrentActor } from "@cadencia/identity/CurrentActor.context";
import { NotYours } from "@cadencia/identity/NotYours.rejection";
import { WeekNumber } from "@cadencia/kernel/Calendar/Week";
import { EntityKey } from "@cadencia/kernel/EntityKey";
import { planIdFor } from "@cadencia/kernel/Plan.id";
import { Story } from "@alchemy.run/domain/Story";
import { expect, it } from "@effect/vitest";
import * as DateTime from "effect/DateTime";
import { ActivePlan } from "../src/ActivePlan/ActivePlan.aggregate.ts";
import { ActivePlanSwitched, PlanSuperseded, SwitchActivePlan } from "../src/ActivePlan/SwitchActivePlan.command.ts";
import { Calendar, CalendarRefused } from "../src/Plan/Calendar.external.ts";
import {
  AvailabilityExceeded,
  ConcretizeSession,
  DayNotPlanned,
  HardensPlannedSession,
  IntensityAfterHardTraining,
  PurposeMismatch,
  SessionConcretized,
} from "../src/Plan/ConcretizeSession.command.ts";
import { CreatePlan, InvalidPlan, PlanAlreadyExists } from "../src/Plan/CreatePlan.command.ts";
import { CurrentPlan } from "../src/Plan/CurrentPlan.view.ts";
import { DayOutsidePlan } from "../src/Plan/DayOutsidePlan.rejection.ts";
import { ImplausibleToday } from "../src/Plan/ImplausibleToday.rejection.ts";
import {
  DayTaken,
  MoveSession,
  SessionMoved,
  SessionNotFound,
  SessionNotMovable,
} from "../src/Plan/MoveSession.command.ts";
import { Plan } from "../src/Plan/Plan.aggregate.ts";
import type { PlannedSession } from "../src/Plan/PlannedSession.ts";
import { PlanNotActive } from "../src/Plan/PlanNotActive.rejection.ts";
import { RecordCalendarFailure, SessionPublicationFailed } from "../src/Plan/RecordCalendarFailure.command.ts";
import { RecordCalendarPublication, SessionPublished } from "../src/Plan/RecordCalendarPublication.command.ts";
import { DayRequirementRecorded, RecordDayRequirement } from "../src/Plan/RecordDayRequirement.command.ts";
import {
  RecordExternalChange,
  SessionChangedInIntervals,
  SessionRemovedInIntervals,
} from "../src/Plan/RecordExternalChange.command.ts";
import { PlanRetired, RetirePlan } from "../src/Plan/RetirePlan.command.ts";
import { ReviseWeek, WeekRevised } from "../src/Plan/ReviseWeek.command.ts";
import { Planning, PlanningHandlers } from "../src/Planning.model.ts";
import {
  ana,
  anaId,
  basePhase,
  bob,
  day,
  easyFortyFive,
  easyHour,
  endurance,
  evidence,
  FINGERPRINT,
  intensity,
  intervals,
  longRide,
  minutes,
  monday,
  paragraph,
  plan,
  planCreated,
  planId,
  saturday,
  sessionId,
  steady,
  threshold,
  title,
  tuesday,
  weekday,
  workout,
} from "./fixtures.ts";

const { call, clock, fail, given, provide, rejected, succeed, then, view, when } = Story;

const as = (actor: Actor) => provide(CurrentActor, actor);
const at = (iso: string) => DateTime.makeUnsafe(iso);
const story = Story.make(Planning, { layer: PlanningHandlers, stub: [Calendar] });

const published = (s: PlannedSession) => new SessionPublished({ sessionId: s.sessionId, externalId: s.externalId });
/** What the Intervals sync records about a session, as it compared it. */
const seen = (session: PlannedSession, change: "changed" | "removed") =>
  new RecordExternalChange({ externalId: session.externalId, change, observed: session });
const draftOf = ({ day, kind, title, targetMinutes, purpose }: PlannedSession) => ({ day, kind, title, targetMinutes, purpose });
const fingerprint = Fingerprint.make(FINGERPRINT);
const anaPlans = ActivePlan.ref(anaId);
const createBase = () =>
  new CreatePlan({
    title: title("Base block"),
    goal: "endurance",
    objective: null,
    startDay: monday,
    endDay: day("2026-12-20"),
    phases: [basePhase],
    longRideWeekday: weekday(7),
    event: null,
    sessions: [endurance, threshold].map(draftOf),
  });
const requirement = (d: string) => new RecordDayRequirement({ day: day(d), instructions: paragraph("Ride outside"), maxMinutes: null });

it.effect("creating a plan publishes every session to the Intervals calendar", () =>
  story(
    as(ana),
    when(
      plan,
      new CreatePlan({
        title: title("Base block"),
        goal: "endurance",
        objective: null,
        startDay: monday,
        endDay: day("2026-12-20"),
        phases: [basePhase],
        longRideWeekday: weekday(7),
        event: null,
        sessions: [endurance, threshold].map(draftOf),
      }),
    ),
    then(plan, planCreated([endurance, threshold])),
    // Stories start their clock at 2026-01-01.
    then(anaPlans, new ActivePlanSwitched({ planId, previous: null, createdAt: at("2026-01-01T00:00:00Z") })),
    call(Calendar.publishSession, { athleteId: anaId, session: endurance }),
    succeed(Calendar.publishSession, { published: true }),
    call(Calendar.publishSession, { athleteId: anaId, session: threshold }),
    succeed(Calendar.publishSession, { published: true }),
    then(plan, published(endurance), published(threshold)),
    view(CurrentPlan, anaId, (v) => {
      expect(v.status).toBe("active");
      expect(v.sessions.map((s) => s.status)).toEqual(["published", "published"]);
    }),
  ),
);

it.effect("a plan can't hold two sessions on one day", () =>
  story(
    as(ana),
    when(
      plan,
      new CreatePlan({
        title: title("Base"),
        goal: "endurance",
        objective: null,
        startDay: monday,
        endDay: saturday,
        phases: [],
        longRideWeekday: weekday(7),
        event: null,
        sessions: [endurance, endurance].map(draftOf),
      }),
    ),
    rejected(new InvalidPlan({ reason: "twoSessionsOneDay" })),
  ),
);

it.effect("an easy proposal for an easy day becomes concrete and is published", () =>
  story(
    given(plan, planCreated()),
    as(ana),
    when(plan, new ConcretizeSession({ day: monday, workout: easyHour, evidence: evidence() })),
    then(
      plan,
      new SessionConcretized({ session: { ...endurance, status: "concrete", workout: easyHour }, softened: false, fingerprint }),
    ),
    call(Calendar.publishSession, { athleteId: anaId, session: { ...endurance, status: "concrete", workout: easyHour } }),
    succeed(Calendar.publishSession, { published: true }),
    then(plan, published(endurance)),
  ),
);

it.effect("readiness can soften a session, never harden it beyond the plan", () =>
  story(
    given(plan, planCreated()),
    as(ana),
    when(plan, new ConcretizeSession({ day: monday, workout: intervals, evidence: evidence() })),
    rejected(
      new HardensPlannedSession({ day: monday, planned: "endurance", proposed: "threshold", peakIntensity: intensity(0.98) }),
    ),
    when(plan, new ConcretizeSession({ day: monday, workout: easyFortyFive, evidence: evidence() })),
    then(
      plan,
      new SessionConcretized({
        session: { ...endurance, status: "concrete", workout: easyFortyFive },
        softened: true,
        fingerprint,
      }),
    ),
    call(Calendar.publishSession, { athleteId: anaId, session: { ...endurance, status: "concrete", workout: easyFortyFive } }),
    succeed(Calendar.publishSession, { published: true }),
    then(plan, published(endurance)),
  ),
);

it.effect("availability in Intervals and the athlete's own limit cap the day", () =>
  story(
    given(plan, planCreated()),
    as(ana),
    when(plan, new ConcretizeSession({ day: monday, workout: easyHour, evidence: evidence([{ day: monday, maxMinutes: 45 }]) })),
    rejected(new AvailabilityExceeded({ day: monday, allowedMinutes: minutes(45), proposedMinutes: minutes(60) })),
    when(plan, new RecordDayRequirement({ day: monday, instructions: paragraph("Short one today"), maxMinutes: minutes(30) })),
    then(
      plan,
      new DayRequirementRecorded({
        requirement: { day: monday, instructions: paragraph("Short one today"), maxMinutes: minutes(30) },
      }),
      // The limit trims the planned session at once, and the calendar follows.
      new WeekRevised({ sessions: [{ ...endurance, targetMinutes: minutes(30) }] }),
    ),
    call(Calendar.publishSession, { athleteId: anaId, session: { ...endurance, targetMinutes: minutes(30) } }),
    succeed(Calendar.publishSession, { published: true }),
    then(plan, published(endurance)),
    when(plan, new ConcretizeSession({ day: monday, workout: easyFortyFive, evidence: evidence() })),
    rejected(new AvailabilityExceeded({ day: monday, allowedMinutes: minutes(30), proposedMinutes: minutes(45) })),
    when(plan, new ConcretizeSession({ day: monday, workout: easyFortyFive, evidence: evidence([{ day: monday, unavailable: true }]) })),
    rejected(new AvailabilityExceeded({ day: monday, allowedMinutes: minutes(0), proposedMinutes: minutes(45) })),
  ),
);

it.effect("riding stays easy after a hard gym session", () =>
  story(
    given(plan, planCreated()),
    as(ana),
    when(
      plan,
      new ConcretizeSession({ day: tuesday, workout: intervals, evidence: evidence([{ day: tuesday, hardOtherTraining: true }]) }),
    ),
    rejected(new IntensityAfterHardTraining({ day: tuesday, proposed: "threshold", peakIntensity: intensity(0.98) })),
  ),
);

it.effect("an opener needs an event the next day", () =>
  story(
    given(plan, planCreated()),
    as(ana),
    when(
      plan,
      new ConcretizeSession({
        day: tuesday,
        workout: workout("openerActivation", [steady("Warm-up", 20, 0.6), steady("Effort", 1, 1.05), steady("Easy", 10, 0.55)]),
        evidence: evidence(),
      }),
    ),
    rejected(new PurposeMismatch({ day: tuesday, problem: "openerWithoutEvent" })),
  ),
);

it.effect("an athlete has one plan under each id", () =>
  story(given(plan, planCreated()), as(ana), when(plan, createBase()), rejected(new PlanAlreadyExists())),
);

it.effect("only the athlete may create or change their plan", () =>
  story(
    as(bob),
    when(plan, createBase()),
    rejected(new NotYours()),
    given(plan, planCreated()),
    when(plan, new ConcretizeSession({ day: monday, workout: easyHour, evidence: evidence() })),
    rejected(new NotYours()),
    when(plan, new MoveSession({ sessionId: longRide.sessionId, toDay: day("2026-11-15") })),
    rejected(new NotYours()),
    when(plan, new ReviseWeek({ limits: [{ day: tuesday, maxMinutes: null, unavailable: true }], today: monday })),
    rejected(new NotYours()),
    when(plan, requirement("2026-11-11")),
    rejected(new NotYours()),
    when(plan, new RetirePlan({ today: day("2026-11-12") })),
    rejected(new NotYours()),
  ),
);

it.effect("a plan that was never created, or was retired, takes no changes", () =>
  story(
    as(ana),
    when(plan, new ConcretizeSession({ day: monday, workout: easyHour, evidence: evidence() })),
    rejected(new PlanNotActive()),
    when(plan, new ReviseWeek({ limits: [], today: monday })),
    rejected(new PlanNotActive()),
    when(plan, new RetirePlan({ today: day("2026-11-12") })),
    rejected(new PlanNotActive()),
    given(plan, planCreated(), new PlanRetired({ withdrawn: [] })),
    when(plan, new MoveSession({ sessionId: longRide.sessionId, toDay: day("2026-11-15") })),
    rejected(new PlanNotActive()),
    when(plan, requirement("2026-11-11")),
    rejected(new PlanNotActive()),
  ),
);

it.effect("moves and day requirements stay inside the plan's sessions and dates", () =>
  story(
    given(plan, planCreated()),
    as(ana),
    when(plan, new MoveSession({ sessionId: sessionId("2026-11-11"), toDay: day("2026-11-12") })),
    rejected(new SessionNotFound({ sessionId: sessionId("2026-11-11") })),
    when(plan, new MoveSession({ sessionId: longRide.sessionId, toDay: day("2027-01-10") })),
    rejected(new DayOutsidePlan({ day: day("2027-01-10"), startDay: monday, endDay: day("2026-12-20") })),
    when(plan, requirement("2026-11-08")),
    rejected(new DayOutsidePlan({ day: day("2026-11-08"), startDay: monday, endDay: day("2026-12-20") })),
    when(plan, requirement("2026-11-11")),
    then(
      plan,
      new DayRequirementRecorded({
        requirement: { day: day("2026-11-11"), instructions: paragraph("Ride outside"), maxMinutes: null },
      }),
    ),
  ),
);

it.effect("a session the athlete changed in Intervals is theirs: Cadencia stops proposing for it", () =>
  story(
    given(plan, planCreated(), published(endurance)),
    as(system("IntervalsSync")),
    when(plan, seen(endurance, "changed")),
    then(plan, new SessionChangedInIntervals({ sessionId: endurance.sessionId })),
    as(ana),
    when(plan, new ConcretizeSession({ day: monday, workout: easyHour, evidence: evidence() })),
    rejected(new DayNotPlanned({ day: monday })),
  ),
);

it.effect("moving a session republishes it on its new day", () =>
  story(
    given(plan, planCreated()),
    as(ana),
    when(plan, new MoveSession({ sessionId: longRide.sessionId, toDay: tuesday })),
    rejected(new DayTaken({ day: tuesday })),
    when(plan, new MoveSession({ sessionId: longRide.sessionId, toDay: day("2026-11-15") })),
    then(plan, new SessionMoved({ session: { ...longRide, day: day("2026-11-15") }, fromDay: saturday })),
    call(Calendar.publishSession, { athleteId: anaId, session: { ...longRide, day: day("2026-11-15") } }),
    succeed(Calendar.publishSession, { published: true }),
    then(plan, published(longRide)),
  ),
);

it.effect("an unavailable day is skipped and taken off the calendar", () =>
  story(
    clock("2026-11-09T08:00:00Z"),
    given(plan, planCreated()),
    as(ana),
    when(plan, new ReviseWeek({ limits: [{ day: tuesday, maxMinutes: null, unavailable: true }], today: monday })),
    then(plan, new WeekRevised({ sessions: [{ ...threshold, status: "skipped", targetMinutes: minutes(0), workout: null }] })),
    call(Calendar.withdrawSession, { athleteId: anaId, externalId: threshold.externalId }),
    succeed(Calendar.withdrawSession, { withdrawn: true }),
  ),
);

it.effect("a session moved onto a day with a requirement keeps to it", () =>
  story(
    given(plan, planCreated()),
    as(ana),
    when(plan, new RecordDayRequirement({ day: day("2026-11-11"), instructions: paragraph("Short day"), maxMinutes: minutes(30) })),
    then(
      plan,
      new DayRequirementRecorded({
        requirement: { day: day("2026-11-11"), instructions: paragraph("Short day"), maxMinutes: minutes(30) },
      }),
    ),
    when(plan, new MoveSession({ sessionId: threshold.sessionId, toDay: day("2026-11-11") })),
    then(plan, new SessionMoved({ session: { ...threshold, day: day("2026-11-11"), targetMinutes: minutes(30) }, fromDay: tuesday })),
    call(Calendar.publishSession, {
      athleteId: anaId,
      session: { ...threshold, day: day("2026-11-11"), targetMinutes: minutes(30) },
    }),
    succeed(Calendar.publishSession, { published: true }),
    then(plan, published(threshold)),
  ),
);

it.effect("two limits for one day keep the strictest, in either order", () =>
  story(
    clock("2026-11-09T08:00:00Z"),
    given(plan, planCreated()),
    as(ana),
    when(
      plan,
      new ReviseWeek({
        limits: [
          { day: tuesday, maxMinutes: null, unavailable: true },
          { day: tuesday, maxMinutes: minutes(60), unavailable: false },
          { day: saturday, maxMinutes: minutes(120), unavailable: false },
          { day: saturday, maxMinutes: minutes(90), unavailable: false },
        ],
        today: monday,
      }),
    ),
    then(
      plan,
      new WeekRevised({
        sessions: [
          { ...threshold, status: "skipped", targetMinutes: minutes(0), workout: null },
          { ...longRide, targetMinutes: minutes(90) },
        ],
      }),
    ),
    call(Calendar.withdrawSession, { athleteId: anaId, externalId: threshold.externalId }),
    succeed(Calendar.withdrawSession, { withdrawn: true }),
    call(Calendar.publishSession, { athleteId: anaId, session: { ...longRide, targetMinutes: minutes(90) } }),
    succeed(Calendar.publishSession, { published: true }),
    then(plan, published(longRide)),
    view(CurrentPlan, anaId, (v) => {
      expect(v.sessions.map((s) => [s.day, s.status, s.targetMinutes])).toEqual([
        [monday, "provisional", 60],
        [tuesday, "skipped", 0],
        [saturday, "published", 90],
      ]);
    }),
  ),
);

it.effect("retiring a plan withdraws its upcoming sessions", () =>
  story(
    clock("2026-11-12T08:00:00Z"),
    given(plan, planCreated()),
    as(ana),
    when(plan, new RetirePlan({ today: day("2026-11-12") })),
    then(plan, new PlanRetired({ withdrawn: [longRide.externalId] })),
    call(Calendar.withdrawSession, { athleteId: anaId, externalId: longRide.externalId }),
    succeed(Calendar.withdrawSession, { withdrawn: true }),
    view(CurrentPlan, anaId, (v) => expect(v.status).toBe("retired")),
  ),
);

const nextPlanId = planIdFor(anaId, EntityKey.make("6a1f0c3e-2b4d-4c5e-9f60-718293a4b5c6"));
const skippedThreshold = { ...threshold, status: "skipped" as const, targetMinutes: minutes(0), workout: null };

it.effect("a plan the athlete creates replaces their previous one, which is retired once", () =>
  story(
    clock("2026-11-12T08:00:00Z"),
    given(plan, planCreated()),
    given(anaPlans, new ActivePlanSwitched({ planId, previous: null })),
    as(systemActor("PlanReplacement")),
    when(anaPlans, new SwitchActivePlan({ planId: nextPlanId, createdAt: at("2026-11-12T07:00:00Z") })),
    then(anaPlans, new ActivePlanSwitched({ planId: nextPlanId, previous: planId, createdAt: at("2026-11-12T07:00:00Z") })),
    // From the day of the switch: the long ride on Saturday leaves the calendar, Monday and Tuesday stay.
    then(plan, new PlanRetired({ withdrawn: [longRide.externalId] })),
    call(Calendar.withdrawSession, { athleteId: anaId, externalId: longRide.externalId }),
    succeed(Calendar.withdrawSession, { withdrawn: true }),
    // The policy runs again: the switch already happened, nothing else is retired.
    when(anaPlans, new SwitchActivePlan({ planId: nextPlanId, createdAt: at("2026-11-12T07:00:00Z") })),
    then(anaPlans),
    view(CurrentPlan, anaId, (v) => expect(v.status).toBe("retired")),
  ),
);

it.effect("a plan created before the active one is retired, whenever its creation arrives", () =>
  story(
    clock("2026-11-12T08:00:00Z"),
    given(plan, planCreated()),
    given(anaPlans, new ActivePlanSwitched({ planId: nextPlanId, previous: null, createdAt: at("2026-11-12T07:00:00Z") })),
    as(systemActor("PlanReplacement")),
    when(anaPlans, new SwitchActivePlan({ planId, createdAt: at("2026-11-11T07:00:00Z") })),
    then(anaPlans, new PlanSuperseded({ planId, by: nextPlanId })),
    then(plan, new PlanRetired({ withdrawn: [longRide.externalId] })),
    call(Calendar.withdrawSession, { athleteId: anaId, externalId: longRide.externalId }),
    succeed(Calendar.withdrawSession, { withdrawn: true }),
  ),
);

it.effect("a draft becomes a plan only if its dates, sessions, phases and event fit together", () =>
  story(
    as(ana),
    when(plan, new CreatePlan({ ...createBase(), endDay: day("2026-11-01") })),
    rejected(new InvalidPlan({ reason: "endsBeforeStart" })),
    when(plan, new CreatePlan({ ...createBase(), sessions: [] })),
    rejected(new InvalidPlan({ reason: "noSessions" })),
    when(plan, new CreatePlan({ ...createBase(), sessions: [draftOf({ ...endurance, day: day("2027-01-04") })] })),
    rejected(new InvalidPlan({ reason: "sessionOutsideDates" })),
    when(plan, new CreatePlan({ ...createBase(), phases: [] })),
    rejected(new InvalidPlan({ reason: "phasesDontCoverPlan" })),
    when(plan, new CreatePlan({ ...createBase(), phases: [{ ...basePhase, endWeek: WeekNumber.make(5) }] })),
    rejected(new InvalidPlan({ reason: "phasesDontCoverPlan" })),
    when(
      plan,
      new CreatePlan({
        ...createBase(),
        event: { name: title("Gran fondo"), day: day("2027-02-01"), distanceKm: null, isRace: false, objective: paragraph("Finish") },
      }),
    ),
    rejected(new InvalidPlan({ reason: "eventOutsidePlan" })),
    when(plan, new CreatePlan({ ...createBase(), goal: "event" })),
    rejected(new InvalidPlan({ reason: "eventGoalWithoutEvent" })),
    // The plan id names its athlete: Ana can't create one of Bob's plans.
    when(Plan.ref(planIdFor(AthleteId.make("i200"), EntityKey.make("6a1f0c3e-2b4d-4c5e-9f60-718293a4b5c6"))), createBase()),
    rejected(new NotYours()),
  ),
);

it.effect("the plan says what it aims for", () =>
  story(
    given(plan, planCreated(undefined, paragraph("Ride 160 km comfortably"))),
    view(CurrentPlan, anaId, (v) => expect(v.objective).toBe("Ride 160 km comfortably")),
  ),
);

it.effect("sessions taken over in Intervals or skipped don't move, and a skipped day stays taken", () =>
  story(
    given(
      plan,
      planCreated(),
      published(endurance),
      new SessionChangedInIntervals({ sessionId: endurance.sessionId }),
      new WeekRevised({ sessions: [skippedThreshold] }),
    ),
    as(ana),
    when(plan, new MoveSession({ sessionId: endurance.sessionId, toDay: day("2026-11-11") })),
    rejected(new SessionNotMovable({ sessionId: endurance.sessionId, status: "changedInIntervals" })),
    when(plan, new MoveSession({ sessionId: threshold.sessionId, toDay: day("2026-11-11") })),
    rejected(new SessionNotMovable({ sessionId: threshold.sessionId, status: "skipped" })),
    when(plan, new MoveSession({ sessionId: longRide.sessionId, toDay: tuesday })),
    rejected(new DayTaken({ day: tuesday })),
  ),
);

it.effect("only the Intervals sync takes over sessions, and only as Cadencia published them", () =>
  story(
    given(plan, planCreated(), published(endurance)),
    as(ana),
    when(plan, seen(endurance, "changed")),
    rejected(new NotYours()),
    as(systemActor("IntervalsSync")),
    // Threshold isn't published yet: what Intervals shows can't be the athlete's change.
    when(plan, seen(threshold, "removed")),
    then(plan),
    when(plan, seen(endurance, "changed")),
    then(plan, new SessionChangedInIntervals({ sessionId: endurance.sessionId })),
    when(plan, seen(endurance, "changed")),
    then(plan),
    when(plan, seen(endurance, "removed")),
    then(plan, new SessionRemovedInIntervals({ sessionId: endurance.sessionId })),
    when(plan, seen(endurance, "removed")),
    then(plan),
  ),
);

it.effect("an observation of a session that was moved since is stale, and is ignored", () =>
  story(
    given(
      plan,
      planCreated(),
      published(longRide),
      new SessionMoved({ session: { ...longRide, day: day("2026-11-15") }, fromDay: saturday }),
      published(longRide),
    ),
    as(systemActor("IntervalsSync")),
    // The sync read Saturday's version before the move: Intervals now shows Sunday, which isn't the athlete's doing.
    when(plan, seen(longRide, "changed")),
    then(plan),
    when(plan, seen(longRide, "removed")),
    then(plan),
    when(plan, seen({ ...longRide, day: day("2026-11-15") }, "changed")),
    then(plan, new SessionChangedInIntervals({ sessionId: longRide.sessionId })),
  ),
);

it.effect("a publication counts only for the version of the session that was published", () =>
  story(
    given(plan, planCreated()),
    as(systemActor("CalendarPublishing")),
    when(plan, new RecordCalendarPublication({ published: { ...endurance, targetMinutes: minutes(30) } })),
    then(plan),
    when(plan, new RecordCalendarPublication({ published: endurance })),
    then(plan, published(endurance)),
    when(plan, new RecordCalendarPublication({ published: endurance })),
    then(plan),
    when(plan, new RecordCalendarFailure({ sessionId: sessionId("2026-11-11"), problem: "refused" })),
    then(plan),
  ),
);

it.effect("a session the calendar refuses is recorded, so the athlete sees it", () =>
  story(
    given(plan, planCreated()),
    as(ana),
    when(plan, new RecordDayRequirement({ day: monday, instructions: paragraph("Short one today"), maxMinutes: minutes(30) })),
    then(
      plan,
      new DayRequirementRecorded({ requirement: { day: monday, instructions: paragraph("Short one today"), maxMinutes: minutes(30) } }),
      new WeekRevised({ sessions: [{ ...endurance, targetMinutes: minutes(30) }] }),
    ),
    call(Calendar.publishSession, { athleteId: anaId, session: { ...endurance, targetMinutes: minutes(30) } }),
    fail(Calendar.publishSession, new CalendarRefused({ problem: "notConnected" })),
    then(plan, new SessionPublicationFailed({ sessionId: endurance.sessionId, problem: "notConnected" })),
    view(CurrentPlan, anaId, (v) =>
      expect(v.calendarProblems).toEqual([{ sessionId: endurance.sessionId, problem: "notConnected" }]),
    ),
  ),
);

it.effect("limits and retirement start from the athlete's today, which must be plausible", () =>
  story(
    clock("2026-11-10T08:00:00Z"),
    given(plan, planCreated()),
    as(ana),
    // Monday is past for the athlete: a late intent doesn't touch it.
    when(plan, new ReviseWeek({ limits: [{ day: monday, maxMinutes: null, unavailable: true }], today: tuesday })),
    then(plan),
    when(plan, new ReviseWeek({ limits: [], today: day("2026-11-20") })),
    rejected(new ImplausibleToday({ today: day("2026-11-20") })),
    when(plan, new RetirePlan({ today: day("2026-11-01") })),
    rejected(new ImplausibleToday({ today: day("2026-11-01") })),
  ),
);
