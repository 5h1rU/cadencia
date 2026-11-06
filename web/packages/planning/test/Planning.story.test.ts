import { Fingerprint } from "@cadencia/athlete/Evidence";
import { system } from "@cadencia/identity/Actor";
import type { Actor } from "@cadencia/identity/Actor";
import { CurrentActor } from "@cadencia/identity/CurrentActor.context";
import { NotYours } from "@cadencia/identity/NotYours.rejection";
import { Story } from "@alchemy.run/domain/Story";
import { expect, it } from "@effect/vitest";
import { AvailabilityExceeded } from "../src/Plan/AvailabilityExceeded.rejection.ts";
import { Calendar } from "../src/Plan/Calendar.external.ts";
import {
  ConcretizeSession,
  DayNotPlanned,
  IntensityAfterHardTraining,
  PurposeMismatch,
  SessionConcretized,
} from "../src/Plan/ConcretizeSession.command.ts";
import { CreatePlan, InvalidPlan, PlanAlreadyExists } from "../src/Plan/CreatePlan.command.ts";
import { CurrentPlan } from "../src/Plan/CurrentPlan.view.ts";
import { DayOutsidePlan } from "../src/Plan/DayOutsidePlan.rejection.ts";
import { HardensPlannedSession } from "../src/Plan/HardensPlannedSession.rejection.ts";
import { DayTaken, MoveSession, SessionMoved } from "../src/Plan/MoveSession.command.ts";
import { PlanNotActive } from "../src/Plan/PlanNotActive.rejection.ts";
import type { PlannedSession } from "../src/Plan/PlanShape.ts";
import { SessionPublished } from "../src/Plan/RecordCalendarPublication.command.ts";
import { DayRequirementRecorded, RecordDayRequirement } from "../src/Plan/RecordDayRequirement.command.ts";
import { RecordExternalChange, SessionChangedInIntervals } from "../src/Plan/RecordExternalChange.command.ts";
import { PlanRetired, RetirePlan } from "../src/Plan/RetirePlan.command.ts";
import { ReviseWeek, WeekRevised } from "../src/Plan/ReviseWeek.command.ts";
import { SessionNotFound } from "../src/Plan/SessionNotFound.rejection.ts";
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
  eventId,
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
  saturday,
  sessionId,
  steady,
  threshold,
  title,
  tuesday,
  weekday,
  workout,
} from "./fixtures.ts";

const { call, clock, given, provide, rejected, succeed, then, view, when } = Story;

const as = (actor: Actor) => provide(CurrentActor, actor);
const story = Story.make(Planning, { layer: PlanningHandlers, stub: [Calendar] });

const published = (s: PlannedSession) => new SessionPublished({ sessionId: s.sessionId, externalId: s.externalId });
const draftOf = ({ day, kind, title, targetMinutes, purpose }: PlannedSession) => ({ day, kind, title, targetMinutes, purpose });
const fingerprint = Fingerprint.make(FINGERPRINT);
const createBase = () =>
  new CreatePlan({
    athleteId: anaId,
    title: title("Base block"),
    goal: "endurance",
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
        athleteId: anaId,
        title: title("Base block"),
        goal: "endurance",
        startDay: monday,
        endDay: day("2026-12-20"),
        phases: [basePhase],
        longRideWeekday: weekday(7),
        event: null,
        sessions: [endurance, threshold].map(draftOf),
      }),
    ),
    then(plan, planCreated([endurance, threshold])),
    call(Calendar.publishSession, { athleteId: anaId, session: endurance }),
    succeed(Calendar.publishSession, { eventId: eventId(1) }),
    call(Calendar.publishSession, { athleteId: anaId, session: threshold }),
    succeed(Calendar.publishSession, { eventId: null }),
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
        athleteId: anaId,
        title: title("Base"),
        goal: "endurance",
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
    succeed(Calendar.publishSession, { eventId: eventId(7) }),
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
    succeed(Calendar.publishSession, { eventId: eventId(7) }),
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
    ),
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
    when(plan, new ReviseWeek({ limits: [{ day: tuesday, maxMinutes: null, unavailable: true }] })),
    rejected(new NotYours()),
    when(plan, requirement("2026-11-11")),
    rejected(new NotYours()),
    when(plan, new RetirePlan({})),
    rejected(new NotYours()),
  ),
);

it.effect("a plan that was never created, or was retired, takes no changes", () =>
  story(
    as(ana),
    when(plan, new ConcretizeSession({ day: monday, workout: easyHour, evidence: evidence() })),
    rejected(new PlanNotActive()),
    when(plan, new ReviseWeek({ limits: [] })),
    rejected(new PlanNotActive()),
    when(plan, new RetirePlan({})),
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
    given(plan, planCreated()),
    as(system("IntervalsSync")),
    when(plan, new RecordExternalChange({ externalId: endurance.externalId, change: "changed" })),
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
    succeed(Calendar.publishSession, { eventId: eventId(9) }),
    then(plan, published(longRide)),
  ),
);

it.effect("an unavailable day is skipped and taken off the calendar", () =>
  story(
    given(plan, planCreated()),
    as(ana),
    when(plan, new ReviseWeek({ limits: [{ day: tuesday, maxMinutes: null, unavailable: true }] })),
    then(plan, new WeekRevised({ sessions: [{ ...threshold, status: "skipped", targetMinutes: minutes(0), workout: null }] })),
    call(Calendar.withdrawSession, { athleteId: anaId, externalId: threshold.externalId }),
    succeed(Calendar.withdrawSession, { withdrawn: true }),
  ),
);

it.effect("retiring a plan withdraws its upcoming sessions", () =>
  story(
    clock("2026-11-12T08:00:00Z"),
    given(plan, planCreated()),
    as(ana),
    when(plan, new RetirePlan({})),
    then(plan, new PlanRetired({ withdrawn: [longRide.externalId] })),
    call(Calendar.withdrawSession, { athleteId: anaId, externalId: longRide.externalId }),
    succeed(Calendar.withdrawSession, { withdrawn: true }),
    view(CurrentPlan, anaId, (v) => expect(v.status).toBe("retired")),
  ),
);
