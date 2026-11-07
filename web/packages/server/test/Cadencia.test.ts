import { Count } from "@cadencia/coach/Count";
import { EvidenceSnapshot } from "@cadencia/athlete/Evidence";
import { AthleteCoachApi } from "@cadencia/coach/AthleteCoachApi.api";
import { CoachNote } from "@cadencia/coach/CoachNote";
import { consultationIdFor } from "@cadencia/coach/Consultation/Consultation.id";
import { PlanDraft } from "@cadencia/coach/Consultation/PlanDraft";
import { conversationIdFor, monthOf } from "@cadencia/coach/Conversation/Conversation.id";
import { dailyDecisionIdFor } from "@cadencia/coach/DailyDecision/DailyDecision.id";
import { DeviceCoachApi } from "@cadencia/coach/DeviceCoachApi.api";
import { Planner, requestFor } from "@cadencia/coach/Planner.external";
import { ModelName } from "@cadencia/coach/Provenance";
import { athlete } from "@cadencia/identity/Actor";
import { AthleteId } from "@cadencia/identity/Athlete.id";
import { Day } from "@cadencia/kernel/Calendar/Day";
import { EntityKey } from "@cadencia/kernel/EntityKey";
import { planIdFor } from "@cadencia/kernel/Plan.id";
import { Workout, WorkoutStep } from "@cadencia/kernel/Training/Workout";
import { AthletePlanningApi } from "@cadencia/planning/AthletePlanningApi.api";
import { Calendar } from "@cadencia/planning/Plan/Calendar.external";
import { PlannedSession } from "@cadencia/planning/Plan/PlannedSession";
import * as Domain from "@alchemy.run/domain";
import { describe, expect, it } from "@effect/vitest";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as Schema from "effect/Schema";
import type * as Scope from "effect/Scope";
import * as Stream from "effect/Stream";
import { CoachHosted, overCoach, overPlanning, PlanningHosted } from "../src/Hosting.ts";
import { changeOf } from "../src/Intervals/ChangeSync.ts";
import { calendarEntry } from "../src/Intervals/IntervalsCalendar.ts";
import { IntervalsEventId } from "../src/Intervals/IntervalsHttp.ts";
import { workoutText } from "../src/Intervals/WorkoutText.ts";
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
        return { published: true };
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

/** Each test gets a fresh World, and a fresh record of what the calendar was asked to show. */
const inCadencia = <A, E>(effect: Effect.Effect<A, E, Scope.Scope | Layer.Success<typeof World>>) =>
  Effect.sync(() => published.splice(0)).pipe(Effect.andThen(effect), Effect.scoped, Effect.provide(World));

const anaId = AthleteId.make("i100");
const ana = athlete("i100");
const bob = athlete("i200");
const device = (who = ana) => overCoach(DeviceCoachApi.clientInProcess).pipe(Effect.provide(signedInAs(who)));
const coach = (who = ana) => overCoach(AthleteCoachApi.clientInProcess).pipe(Effect.provide(signedInAs(who)));
const planning = (who = ana) => overPlanning(AthletePlanningApi.clientInProcess).pipe(Effect.provide(signedInAs(who)));

const monday = Schema.decodeUnknownSync(Day)("2026-11-09");
const planId = planIdFor(anaId, EntityKey.make("0b6f5a2e-1c3d-4e5f-8a9b-0c1d2e3f4a5b"));
const consultation = consultationIdFor(anaId, EntityKey.make("7c9e6679-7425-40de-944b-e07fc1f90ae7"));
const decision = dailyDecisionIdFor(anaId, monday);
const model = ModelName.make("gpt-5.5");

const draft = Schema.decodeUnknownSync(PlanDraft)({
  title: "Base block",
  goal: "endurance",
  objective: "Build an aerobic base",
  rationale: "Six weeks of easy volume.",
  startDay: "2026-11-09",
  endDay: "2026-12-20",
  phases: [{ focus: "base", startWeek: 1, endWeek: 6, summary: "Aerobic base" }],
  longRideWeekday: 7,
  event: null,
  sessions: [{ day: "2026-11-09", kind: "endurance", title: "Easy endurance", targetMinutes: 60, purpose: "Aerobic base" }],
});
const evidence = Schema.decodeUnknownSync(EvidenceSnapshot)({
  fingerprint: "b".repeat(64),
  readiness: { level: "normal", score: 62, summary: "Typical HRV and sleep." },
  days: [],
  eventDays: [],
});
const steady = (minutes: number, intensity: number, endIntensity = intensity) =>
  Schema.decodeUnknownSync(WorkoutStep)({
    name: `${Math.round(intensity * 100)}%`,
    durationSeconds: minutes * 60,
    startIntensity: intensity,
    endIntensity,
    cadenceRpm: null,
  });
const workout = Schema.decodeUnknownSync(Workout);
const intervals = workout({ name: "Threshold", kind: "threshold", steps: [steady(15, 0.6), steady(30, 0.98), steady(15, 0.55)], intensityCeiling: null, rationale: null });
const easy = workout({ name: "Easy endurance", kind: "endurance", steps: [steady(60, 0.65)], intensityCeiling: null, rationale: "Typical HRV." });
const note = Schema.decodeUnknownSync(CoachNote)({ headline: "Easy endurance", body: "Ready.", session: "One hour in Z2.", watch: null });

const until = <A>(stream: Stream.Stream<{ readonly state: A | null }, unknown>, done: (a: A) => boolean) =>
  stream.pipe(
    Stream.map(({ state }) => state),
    Stream.filter((s): s is A => s !== null && done(s)),
    Stream.runHead,
  );

describe("Cadencia: iOS runs the AI, the backend records it and the plan decides", () => {
  it.live("a policy that runs again gets the same answer, and the plan changes once", () =>
    inCadencia(
      Effect.gen(function* () {
        const planner = yield* Planner;
        const accepted = { _tag: "Accepted" };

        // The consultation's policy runs twice for the same DraftAccepted.
        const creation = requestFor({ stream: `Consultation/${consultation}`, seq: 4 });
        expect((yield* planner.createPlan({ requestId: creation, athleteId: anaId, planId, draft })).answer).toEqual(accepted);
        expect((yield* planner.createPlan({ requestId: creation, athleteId: anaId, planId, draft })).answer).toEqual(accepted);
        // A different request for the same plan is a second plan, which Planning refuses.
        const another = requestFor({ stream: `Consultation/${consultation}`, seq: 9 });
        expect((yield* planner.createPlan({ requestId: another, athleteId: anaId, planId, draft })).answer).toMatchObject({
          _tag: "Refused",
          refusal: { reason: "planAlreadyExists" },
        });

        // The decision's policy runs twice for the same attempt: one concretized session.
        const concretize = requestFor({ stream: `DailyDecision/${decision}`, seq: 1 });
        const ask = { requestId: concretize, athleteId: anaId, planId, day: monday, workout: easy, evidence };
        expect((yield* planner.concretizeSession(ask)).answer).toEqual(accepted);
        expect((yield* planner.concretizeSession(ask)).answer).toEqual(accepted);
        const web = yield* planning();
        const plan = yield* until(web.CurrentPlan.watch(anaId), (p) => p.sessions.some((s) => s.workout !== null));
        expect(plan._tag === "Some" && plan.value.sessions.filter((s) => s.day === monday)).toHaveLength(1);
      }),
    ),
  );

  it.live("a consultation creates the plan, which is published to the calendar", () =>
    inCadencia(
      Effect.gen(function* () {
        const ios = yield* device();
        yield* ios.StartConsultation(consultation, {});
        yield* ios.RecordDraft(consultation, { draft, model, interpretedOn: "ios" });
        yield* ios.AcceptDraft(consultation, { planId, draftRevision: Count.make(1) });

        const web = yield* planning();
        const plan = yield* until(web.CurrentPlan.watch(anaId), (p) => p.sessions.every((s) => s.status === "published"));
        expect(plan).toMatchObject({ _tag: "Some", value: { status: "active", title: "Base block" } });
        expect(published).toEqual(["2026-11-09 endurance provisional"]);
      }),
    ),
  );

  it.live("the AI's proposal is checked by the plan: a harder session is refused, an easy one accepted", () =>
    inCadencia(
      Effect.gen(function* () {
        const ios = yield* device();
        yield* ios.StartConsultation(consultation, {});
        yield* ios.RecordDraft(consultation, { draft, model, interpretedOn: "ios" });
        yield* ios.AcceptDraft(consultation, { planId, draftRevision: Count.make(1) });
        const web = yield* planning();
        yield* until(web.CurrentPlan.watch(anaId), (p) => p.status === "active");

        const day = decision;
        const proposal = { planId, note, evidence, model, interpretedOn: "ios" as const };
        yield* ios.RecordDailyDecision(day, { ...proposal, workout: intervals });
        const reader = yield* coach();
        const refused = yield* until(reader.TodayDecision.watch(day), (d) => d.status === "refused");
        expect(refused).toMatchObject({ _tag: "Some" });
        // Planning's rejection reaches the coach translated, with its evidence.
        expect(refused._tag === "Some" && refused.value.refusal?.reason).toBe("hardensPlan");
        expect(refused._tag === "Some" && refused.value.refusal?.detail).toContain("peakIntensity=0.98");

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
        yield* ios.StartConsultation(consultation, {});
        const stranger = yield* planning(bob);
        const read = yield* stranger.CurrentPlan.get(anaId).pipe(Effect.flip);
        expect(read._tag).toBe("NotYours");
        const strangerDevice = yield* device(bob);
        const write = yield* strangerDevice
          .RecordDailyDecision(decision, { planId, workout: easy, note, evidence, model, interpretedOn: "ios" })
          .pipe(Effect.flip);
        expect(write._tag).toBe("NotYours");
      }),
    ),
  );

  it.live("an athlete's own device can't name someone else's plan", () =>
    inCadencia(
      Effect.gen(function* () {
        const bobsPlan = planIdFor(AthleteId.make("i200"), EntityKey.make("0b6f5a2e-1c3d-4e5f-8a9b-0c1d2e3f4a5b"));
        const ios = yield* device();
        const decide = yield* ios
          .RecordDailyDecision(decision, { planId: bobsPlan, workout: easy, note, evidence, model, interpretedOn: "ios" })
          .pipe(Effect.flip);
        expect(decide._tag).toBe("NotYours");
        yield* ios.StartConsultation(consultation, {});
        yield* ios.RecordDraft(consultation, { draft, model, interpretedOn: "ios" });
        const accept = yield* ios.AcceptDraft(consultation, { planId: bobsPlan, draftRevision: Count.make(1) }).pipe(Effect.flip);
        expect(accept._tag).toBe("NotYours");
        const bobs = yield* planning(bob);
        expect((yield* bobs.CurrentPlan.get(AthleteId.make("i200")))?.status ?? "none").toBe("none");
      }),
    ),
  );

  it.live("an athlete can't read someone else's coach", () =>
    inCadencia(
      Effect.gen(function* () {
        const ios = yield* device();
        yield* ios.StartConsultation(consultation, {});
        const stranger = yield* coach(bob);
        const refusals = yield* Effect.all([
          Effect.flip(stranger.TodayDecision.get(decision)),
          Effect.flip(stranger.ConversationThread.get(conversationIdFor(anaId, monthOf(monday)))),
          Effect.flip(stranger.ConsultationView.get(consultation)),
          Effect.flip(stranger.RiderProfileCard.get(anaId)),
          Effect.flip(stranger.CoachTimeline.get(anaId)),
        ]);
        expect(refusals.map((e) => e._tag)).toEqual(["NotYours", "NotYours", "NotYours", "NotYours", "NotYours"]);
      }),
    ),
  );
});

describe("Intervals adapter", () => {
  const session = Schema.decodeUnknownSync(PlannedSession)({
    sessionId: "2026-11-09",
    day: "2026-11-09",
    kind: "endurance",
    title: "Easy endurance",
    targetMinutes: 60,
    purpose: "Aerobic base",
    status: "published",
    workout: Schema.encodeSync(Workout)(easy),
    externalId: "cadencia-i100-0b6f5a2e-1c3d-4e5f-8a9b-0c1d2e3f4a5b-2026-11-09",
  });

  it("writes workouts in Intervals' workout-builder text", () => {
    expect(workoutText({ ...easy, steps: [steady(10, 0.5), steady(5, 0.6, 0.8)] })).toBe(
      "Typical HRV.\n\n50%\n- 10m 50%\n\n60%\n- 5m ramp 60-80%",
    );
  });

  it("notices when the athlete moved, edited or deleted a session in Intervals", () => {
    const entry = calendarEntry(session);
    const event = {
      id: IntervalsEventId.make(1),
      external_id: entry.external_id,
      start_date_local: entry.start_date_local,
      name: entry.name,
      moving_time: entry.moving_time,
      description: entry.description,
    };
    expect(changeOf(session, event)).toBeNull();
    // Line endings and trailing spaces aren't an edit.
    expect(changeOf(session, { ...event, description: `${entry.description.replace(/\n/g, "\r\n")}  \n` })).toBeNull();
    expect(changeOf(session, { ...event, start_date_local: "2026-11-10T00:00:00" })).toBe("changed");
    expect(changeOf(session, { ...event, moving_time: 1800 })).toBe("changed");
    // Same name and duration, different workout: the athlete edited it.
    expect(changeOf(session, { ...event, description: `${entry.description}\n- 5m 110%` })).toBe("changed");
    expect(changeOf(session, undefined)).toBe("removed");
  });
});
