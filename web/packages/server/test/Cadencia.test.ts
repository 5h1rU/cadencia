import { AthleteCoachApi } from "@cadencia/coach/AthleteCoachApi.api";
import { CoachDeviceApi } from "@cadencia/coach/CoachDeviceApi.api";
import type { PlanDraft } from "@cadencia/coach/Consultation/PlanDraft";
import { DailyDecisionId } from "@cadencia/coach/DailyDecision/DailyDecision.id";
import { ConsultationId } from "@cadencia/coach/Consultation/Consultation.id";
import { athlete } from "@cadencia/kernel/Actor";
import { AthleteId } from "@cadencia/kernel/Athlete.id";
import { Day } from "@cadencia/kernel/Day";
import { type EvidenceSnapshot, Fingerprint } from "@cadencia/kernel/Evidence";
import type { Workout } from "@cadencia/kernel/Workout";
import { AthletePlanningApi } from "@cadencia/planning/AthletePlanningApi.api";
import { Calendar } from "@cadencia/planning/Plan/Calendar.external";
import * as Domain from "@alchemy.run/domain";
import { describe, expect, it } from "@effect/vitest";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import type * as Scope from "effect/Scope";
import * as Stream from "effect/Stream";
import { changeOf } from "../src/Intervals/ChangeSync.ts";
import { calendarEntry } from "../src/Intervals/IntervalsCalendar.ts";
import { workoutText } from "../src/Intervals/WorkoutText.ts";
import { CoachHosted, overCoach, overPlanning, PlanningHosted } from "../src/Hosting.ts";
import { PlanningPlanner } from "../src/Planner.ts";
import { SessionLive } from "../src/Session.ts";
import { SessionKeyTest, signedInAs } from "./session.ts";

/** What the calendar was asked to show, in place of Intervals.icu. */
const published: Array<string> = [];
const FakeCalendar = Calendar.toLayer(
  Effect.succeed({
    publishSession: ({ session }) =>
      Effect.sync(() => {
        published.push(`${session.day} ${session.kind} ${session.status}`);
        return { eventId: published.length };
      }),
    withdrawSession: () => Effect.succeed({ withdrawn: true }),
  }),
);

// Both models in one process, wired as the Worker wires them, on the in-memory platform.
const World = SessionLive.pipe(
  Layer.provideMerge(SessionKeyTest),
  Layer.provideMerge(CoachHosted),
  Layer.provideMerge(PlanningPlanner),
  Layer.provideMerge(PlanningHosted),
  Layer.provide(Layer.mergeAll(FakeCalendar, Domain.InMemory)),
);

const inCadencia = <A, E>(effect: Effect.Effect<A, E, Scope.Scope | Layer.Success<typeof World>>) =>
  effect.pipe(Effect.scoped, Effect.provide(World));

const anaId = AthleteId.make("i100");
const ana = athlete("i100");
const bob = athlete("i200");
const device = (who = ana) => overCoach(CoachDeviceApi.clientInProcess).pipe(Effect.provide(signedInAs(who)));
const coach = (who = ana) => overCoach(AthleteCoachApi.clientInProcess).pipe(Effect.provide(signedInAs(who)));
const planning = (who = ana) => overPlanning(AthletePlanningApi.clientInProcess).pipe(Effect.provide(signedInAs(who)));

const monday = Day.make("2026-11-09");
const draft: PlanDraft = {
  athleteId: anaId,
  title: "Base block",
  goal: "endurance",
  objective: "Build an aerobic base",
  rationale: "Six weeks of easy volume.",
  startDay: monday,
  endDay: Day.make("2026-12-20"),
  phases: [{ focus: "base", startWeek: 1, endWeek: 6, summary: "Aerobic base" }],
  longRideWeekday: 7,
  event: null,
  sessions: [{ day: monday, kind: "endurance", title: "Easy endurance", targetMinutes: 60, purpose: "Aerobic base" }],
};
const evidence: EvidenceSnapshot = {
  fingerprint: Fingerprint.make("fp-1"),
  readiness: { level: "normal", score: 62, summary: "Typical HRV and sleep." },
  days: [],
  eventDays: [],
};
const steady = (minutes: number, intensity: number) => ({
  name: `${Math.round(intensity * 100)}%`,
  durationSeconds: minutes * 60,
  startIntensity: intensity,
  endIntensity: intensity,
});
const intervals: Workout = { name: "Threshold", kind: "threshold", steps: [steady(15, 0.6), steady(30, 0.98), steady(15, 0.55)], rationale: "" };
const easy: Workout = { name: "Easy endurance", kind: "endurance", steps: [steady(60, 0.65)], rationale: "Typical HRV." };
const note = { headline: "Easy endurance", body: "Ready.", session: "One hour in Z2.", watch: null };

const until = <A>(stream: Stream.Stream<{ readonly state: A | null }, unknown>, done: (a: A) => boolean) =>
  stream.pipe(
    Stream.map(({ state }) => state),
    Stream.filter((s): s is A => s !== null && done(s)),
    Stream.runHead,
  );

describe("Cadencia: iOS runs the AI, the backend records it and the plan decides", () => {
  it.live("a consultation creates the plan, which is published to the calendar", () =>
    inCadencia(
      Effect.gen(function* () {
        const ios = yield* device();
        const consultation = ConsultationId.make("i100:c1");
        yield* ios.StartConsultation(consultation, {});
        yield* ios.RecordDraft(consultation, { draft, model: "gpt-5.5", interpretedOn: "ios" });
        yield* ios.AcceptDraft(consultation, { planId: "i100:p1" });

        const web = yield* planning();
        const plan = yield* until(web.CurrentPlan.watch(anaId), (p) => p.sessions.every((s) => s.status === "published"));
        expect(plan).toMatchObject({ _tag: "Some", value: { status: "active", title: "Base block" } });
        expect(published).toContain("2026-11-09 endurance provisional");
      }),
    ),
  );

  it.live("the AI's proposal is checked by the plan: a harder session is refused, an easy one accepted", () =>
    inCadencia(
      Effect.gen(function* () {
        const ios = yield* device();
        yield* ios.StartConsultation(ConsultationId.make("i100:c1"), {});
        yield* ios.RecordDraft(ConsultationId.make("i100:c1"), { draft, model: "gpt-5.5", interpretedOn: "ios" });
        yield* ios.AcceptDraft(ConsultationId.make("i100:c1"), { planId: "i100:p1" });
        const web = yield* planning();
        yield* until(web.CurrentPlan.watch(anaId), (p) => p.status === "active");

        const day = DailyDecisionId.make("i100:2026-11-09");
        const proposal = { planId: "i100:p1", note, evidence, model: "gpt-5.5", interpretedOn: "ios" as const };
        yield* ios.RecordDailyDecision(day, { ...proposal, workout: intervals });
        const reader = yield* coach();
        const refused = yield* until(reader.TodayDecision.watch(day), (d) => d.status === "refused");
        expect(refused).toMatchObject({ _tag: "Some" });
        expect(refused._tag === "Some" && refused.value.refusal).toContain("HardensPlannedSession");

        yield* ios.RecordDailyDecision(day, { ...proposal, workout: easy });
        const accepted = yield* until(reader.TodayDecision.watch(day), (d) => d.status === "accepted" && d.attempt === 2);
        expect(accepted).toMatchObject({ _tag: "Some", value: { interpretedOn: "ios", model: "gpt-5.5" } });
        const plan = yield* until(web.CurrentPlan.watch(anaId), (p) => p.sessions[0]?.workout?.name === "Easy endurance");
        expect(plan._tag).toBe("Some");
      }),
    ),
  );

  it.live("an athlete can't read or change someone else's plan or decisions", () =>
    inCadencia(
      Effect.gen(function* () {
        const ios = yield* device();
        yield* ios.StartConsultation(ConsultationId.make("i100:c1"), {});
        const stranger = yield* planning(bob);
        const read = yield* stranger.CurrentPlan.get(anaId).pipe(Effect.flip);
        expect(read._tag).toBe("NotYours");
        const strangerDevice = yield* device(bob);
        const write = yield* strangerDevice
          .RecordDailyDecision(DailyDecisionId.make("i100:2026-11-09"), {
            planId: "i100:p1",
            workout: easy,
            note,
            evidence,
            model: "gpt-5.5",
            interpretedOn: "ios",
          })
          .pipe(Effect.flip);
        expect(write._tag).toBe("NotYours");
      }),
    ),
  );
});

describe("Intervals adapter", () => {
  const session = {
    sessionId: "2026-11-09",
    day: monday,
    kind: "endurance" as const,
    title: "Easy endurance",
    targetMinutes: 60,
    purpose: "Aerobic base",
    status: "published" as const,
    workout: easy,
    externalId: "cadencia-i100-p1-2026-11-09",
  };

  it("writes workouts in Intervals' workout-builder text", () => {
    expect(workoutText({ ...easy, steps: [steady(10, 0.5), { ...steady(5, 0.6), endIntensity: 0.8 }] })).toBe(
      "Typical HRV.\n\n50%\n- 10m 50%\n\n60%\n- 5m ramp 60-80%",
    );
  });

  it("notices when the athlete moved, edited or deleted a session in Intervals", () => {
    const entry = calendarEntry(session);
    const event = { id: 1, external_id: entry.external_id, start_date_local: entry.start_date_local, name: entry.name, moving_time: entry.moving_time };
    expect(changeOf(session, event)).toBeNull();
    expect(changeOf(session, { ...event, start_date_local: "2026-11-10T00:00:00" })).toBe("changed");
    expect(changeOf(session, { ...event, moving_time: 1800 })).toBe("changed");
    expect(changeOf(session, undefined)).toBe("removed");
  });
});
