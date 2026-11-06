import { CurrentPlan } from "../src/Plan/CurrentPlan.view.ts";
import { Story } from "@alchemy.run/domain/Story";
import { CurrentActor } from "@cadencia/kernel/CurrentActor.context";
import { Fingerprint } from "@cadencia/kernel/Evidence";
import { NotYours } from "@cadencia/kernel/NotYours.rejection";
import type { Actor } from "@cadencia/kernel/Actor";
import { system } from "@cadencia/kernel/Actor";
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
import { CreatePlan, InvalidPlan } from "../src/Plan/CreatePlan.command.ts";
import { HardensPlannedSession } from "../src/Plan/HardensPlannedSession.rejection.ts";
import { DayTaken, MoveSession, SessionMoved } from "../src/Plan/MoveSession.command.ts";
import { SessionPublished } from "../src/Plan/RecordCalendarPublication.command.ts";
import { DayRequirementRecorded, RecordDayRequirement } from "../src/Plan/RecordDayRequirement.command.ts";
import { RecordExternalChange, SessionChangedInIntervals } from "../src/Plan/RecordExternalChange.command.ts";
import { PlanRetired, RetirePlan } from "../src/Plan/RetirePlan.command.ts";
import { ReviseWeek, WeekRevised } from "../src/Plan/ReviseWeek.command.ts";
import { Planning, PlanningHandlers } from "../src/Planning.model.ts";
import {
  ana,
  anaId,
  bob,
  day,
  easyFortyFive,
  easyHour,
  endurance,
  evidence,
  intervals,
  longRide,
  monday,
  plan,
  planCreated,
  saturday,
  steady,
  threshold,
  tuesday,
  workout,
} from "./fixtures.ts";

const { call, clock, given, provide, rejected, succeed, then, view, when } = Story;

const as = (actor: Actor) => provide(CurrentActor, actor);
const story = Story.make(Planning, { layer: PlanningHandlers, stub: [Calendar] });

const published = (s: { sessionId: string; externalId: string }) =>
  new SessionPublished({ sessionId: s.sessionId, externalId: s.externalId });

it.effect("creating a plan publishes every session to the Intervals calendar", () =>
  story(
    as(ana),
    when(
      plan,
      new CreatePlan({
        athleteId: anaId,
        title: "Base block",
        goal: "endurance",
        startDay: monday,
        endDay: day("2026-12-20"),
        phases: [{ focus: "base", startWeek: 1, endWeek: 6, summary: "Aerobic base" }],
        longRideWeekday: 7,
        event: null,
        sessions: [endurance, threshold].map(({ day, kind, title, targetMinutes, purpose }) => ({
          day,
          kind,
          title,
          targetMinutes,
          purpose,
        })),
      }),
    ),
    then(plan, planCreated([endurance, threshold])),
    call(Calendar.publishSession, { athleteId: anaId, session: endurance }),
    succeed(Calendar.publishSession, { eventId: 1 }),
    call(Calendar.publishSession, { athleteId: anaId, session: threshold }),
    succeed(Calendar.publishSession, { eventId: 2 }),
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
        title: "Base",
        goal: "endurance",
        startDay: monday,
        endDay: saturday,
        phases: [],
        longRideWeekday: 7,
        event: null,
        sessions: [endurance, endurance].map(({ day, kind, title, targetMinutes, purpose }) => ({
          day,
          kind,
          title,
          targetMinutes,
          purpose,
        })),
      }),
    ),
    rejected(new InvalidPlan({ reason: "A plan has at most one session per day." })),
  ),
);

it.effect("an easy proposal for an easy day becomes concrete and is published", () =>
  story(
    given(plan, planCreated()),
    as(ana),
    when(plan, new ConcretizeSession({ day: monday, workout: easyHour, evidence: evidence() })),
    then(
      plan,
      new SessionConcretized({
        session: { ...endurance, status: "concrete", workout: easyHour },
        softened: false,
        fingerprint: Fingerprint.make("fp-1"),
      }),
    ),
    call(Calendar.publishSession, {
      athleteId: anaId,
      session: { ...endurance, status: "concrete", workout: easyHour },
    }),
    succeed(Calendar.publishSession, { eventId: 7 }),
    then(plan, published(endurance)),
  ),
);

it.effect("readiness can soften a session, never harden it beyond the plan", () =>
  story(
    given(plan, planCreated()),
    as(ana),
    when(plan, new ConcretizeSession({ day: monday, workout: intervals, evidence: evidence() })),
    rejected(
      new HardensPlannedSession({ day: monday, planned: "endurance", proposed: "threshold", peakIntensity: 0.98 }),
    ),
    when(plan, new ConcretizeSession({ day: monday, workout: easyFortyFive, evidence: evidence() })),
    then(
      plan,
      new SessionConcretized({
        session: { ...endurance, status: "concrete", workout: easyFortyFive },
        softened: true,
        fingerprint: Fingerprint.make("fp-1"),
      }),
    ),
    call(Calendar.publishSession, {
      athleteId: anaId,
      session: { ...endurance, status: "concrete", workout: easyFortyFive },
    }),
    succeed(Calendar.publishSession, { eventId: 7 }),
    then(plan, published(endurance)),
  ),
);

it.effect("availability in Intervals and the athlete's own limit cap the day", () =>
  story(
    given(plan, planCreated()),
    as(ana),
    when(
      plan,
      new ConcretizeSession({ day: monday, workout: easyHour, evidence: evidence([{ day: monday, maxMinutes: 45 }]) }),
    ),
    rejected(new AvailabilityExceeded({ day: monday, allowedMinutes: 45, proposedMinutes: 60 })),
    when(plan, new RecordDayRequirement({ day: monday, instructions: "Short one today", maxMinutes: 30 })),
    then(
      plan,
      new DayRequirementRecorded({
        requirement: { day: monday, instructions: "Short one today", maxMinutes: 30 },
      }),
    ),
    when(plan, new ConcretizeSession({ day: monday, workout: easyFortyFive, evidence: evidence() })),
    rejected(new AvailabilityExceeded({ day: monday, allowedMinutes: 30, proposedMinutes: 45 })),
    when(
      plan,
      new ConcretizeSession({
        day: monday,
        workout: easyFortyFive,
        evidence: evidence([{ day: monday, unavailable: true }]),
      }),
    ),
    rejected(new AvailabilityExceeded({ day: monday, allowedMinutes: 0, proposedMinutes: 45 })),
  ),
);

it.effect("riding stays easy after a hard gym session", () =>
  story(
    given(plan, planCreated()),
    as(ana),
    when(
      plan,
      new ConcretizeSession({
        day: tuesday,
        workout: intervals,
        evidence: evidence([{ day: tuesday, hardOtherTraining: true }]),
      }),
    ),
    rejected(new IntensityAfterHardTraining({ day: tuesday, proposed: "threshold", peakIntensity: 0.98 })),
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
        workout: workout("openerActivation", [
          steady("Warm-up", 20, 0.6),
          steady("Effort", 1, 1.05),
          steady("Easy", 10, 0.55),
        ]),
        evidence: evidence(),
      }),
    ),
    rejected(
      new PurposeMismatch({
        day: tuesday,
        reason: "An opener requires a confirmed event the following day. Choose the actual training purpose otherwise.",
      }),
    ),
  ),
);

it.effect("only the athlete may change their plan", () =>
  story(
    given(plan, planCreated()),
    as(bob),
    when(plan, new ConcretizeSession({ day: monday, workout: easyHour, evidence: evidence() })),
    rejected(new NotYours()),
    when(plan, new RetirePlan({})),
    rejected(new NotYours()),
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
    succeed(Calendar.publishSession, { eventId: 9 }),
    then(plan, published(longRide)),
  ),
);

it.effect("an unavailable day is skipped and taken off the calendar", () =>
  story(
    given(plan, planCreated()),
    as(ana),
    when(plan, new ReviseWeek({ limits: [{ day: tuesday, maxMinutes: null, unavailable: true }] })),
    then(
      plan,
      new WeekRevised({ sessions: [{ ...threshold, status: "skipped", targetMinutes: 0, workout: null }] }),
    ),
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
