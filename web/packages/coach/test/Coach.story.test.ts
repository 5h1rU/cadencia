import { Story } from "@alchemy.run/domain/Story";
import { type Actor, athlete } from "@cadencia/kernel/Actor";
import { AthleteId } from "@cadencia/kernel/Athlete.id";
import { CurrentActor } from "@cadencia/kernel/CurrentActor.context";
import { Day } from "@cadencia/kernel/Day";
import { type EvidenceSnapshot, Fingerprint } from "@cadencia/kernel/Evidence";
import { NotYours } from "@cadencia/kernel/NotYours.rejection";
import type { Workout } from "@cadencia/kernel/Workout";
import { expect, it } from "@effect/vitest";
import { Coach, CoachHandlers } from "../src/Coach.model.ts";
import { CoachTimeline } from "../src/CoachTimeline.view.ts";
import {
  AcceptDraft,
  AnswerQuestion,
  AthleteAnswered,
  CoachAsked,
  ConsultationStarted,
  DraftAccepted,
  DraftProposed,
  DraftRefusedByPlan,
  NoDraft,
  PlanCreatedFromDraft,
  RecordCoachQuestion,
  RecordDraft,
  StartConsultation,
} from "../src/Consultation/Consult.commands.ts";
import { Consultation } from "../src/Consultation/Consultation.aggregate.ts";
import { ConsultationView } from "../src/Consultation/ConsultationView.view.ts";
import type { PlanDraft } from "../src/Consultation/PlanDraft.ts";
import { AcceptIntent, IntentAccepted } from "../src/Conversation/AcceptIntent.command.ts";
import { Conversation } from "../src/Conversation/Conversation.aggregate.ts";
import { ConversationThread } from "../src/Conversation/ConversationThread.view.ts";
import { DismissIntent, IntentDismissed } from "../src/Conversation/DismissIntent.command.ts";
import type { Intent } from "../src/Conversation/Intent.ts";
import { NoOpenIntent } from "../src/Conversation/NoOpenIntent.rejection.ts";
import { CoachReplied, RecordCoachReply } from "../src/Conversation/RecordCoachReply.command.ts";
import { IntentApplied, IntentRefused } from "../src/Conversation/RecordIntentOutcome.command.ts";
import { MessageSent, SendMessage } from "../src/Conversation/SendMessage.command.ts";
import { DailyDecision } from "../src/DailyDecision/DailyDecision.aggregate.ts";
import {
  DailyDecisionRecorded,
  DecisionAlreadyAccepted,
  RecordDailyDecision,
} from "../src/DailyDecision/RecordDailyDecision.command.ts";
import { PlanVerdictRecorded } from "../src/DailyDecision/RecordPlanVerdict.command.ts";
import { TodayDecision } from "../src/DailyDecision/TodayDecision.view.ts";
import { Planner } from "../src/Planner.external.ts";
import { RiderProfile } from "../src/RiderProfile/RiderProfile.aggregate.ts";
import { AutomaticAttemptUsed, ProfileAttempted, RecordProfileAttempt } from "../src/RiderProfile/RiderProfile.commands.ts";

const { call, emitted, given, provide, rejected, succeed, then, view, when } = Story;
const as = (actor: Actor) => provide(CurrentActor, actor);
const story = Story.make(Coach, { layer: CoachHandlers, stub: [Planner] });

const ana = athlete("i100");
const bob = athlete("i200");
const anaId = AthleteId.make("i100");
const today = Day.make("2026-11-09");
const planId = "i100:p1";

const workout: Workout = {
  name: "Easy endurance",
  kind: "endurance",
  steps: [{ name: "Z2", durationSeconds: 3600, startIntensity: 0.65, endIntensity: 0.65 }],
  rationale: "HRV is typical; keep the plan's aerobic day.",
};
const note = { headline: "Easy endurance", body: "Your body is ready.", session: "One hour in Z2.", watch: null };
const evidence = (fp: string): EvidenceSnapshot => ({
  fingerprint: Fingerprint.make(fp),
  readiness: { level: "normal", score: 60, summary: "Typical HRV and sleep." },
  days: [],
  eventDays: [],
});
const proposal = (fp = "fp-1") => ({
  planId,
  workout,
  note,
  evidence: evidence(fp),
  model: "gpt-5.5",
  interpretedOn: "ios" as const,
});

const decision = DailyDecision.ref("i100:2026-11-09");
const thread = Conversation.ref("i100:2026-11");
const consultation = Consultation.ref("i100:c1");
const profile = RiderProfile.ref(anaId);

it.effect("the day's decision goes to the plan, and its answer is recorded", () =>
  story(
    as(ana),
    when(decision, new RecordDailyDecision(proposal())),
    then(decision, new DailyDecisionRecorded({ athleteId: anaId, day: today, attempt: 1, ...proposal() })),
    call(Planner.concretizeSession, { planId, day: today, workout, evidence: evidence("fp-1") }),
    succeed(Planner.concretizeSession, { accepted: true, reason: null }),
    then(decision, new PlanVerdictRecorded({ attempt: 1, accepted: true, reason: null })),
    view(TodayDecision, decision, (v) => {
      expect(v.status).toBe("accepted");
      expect(v.interpretedOn).toBe("ios");
    }),
    when(decision, new RecordDailyDecision(proposal())),
    rejected(new DecisionAlreadyAccepted({ fingerprint: Fingerprint.make("fp-1") })),
    emitted(CoachTimeline, anaId, [
      { kind: "decision", headline: "Easy endurance" },
      { kind: "verdict", headline: "Plan accepted the session" },
    ]),
  ),
);

it.effect("a refused decision can be tried again with the plan's reason", () =>
  story(
    as(ana),
    when(decision, new RecordDailyDecision(proposal())),
    then(decision, new DailyDecisionRecorded({ athleteId: anaId, day: today, attempt: 1, ...proposal() })),
    call(Planner.concretizeSession, { planId, day: today, workout, evidence: evidence("fp-1") }),
    succeed(Planner.concretizeSession, { accepted: false, reason: "HardensPlannedSession" }),
    then(decision, new PlanVerdictRecorded({ attempt: 1, accepted: false, reason: "HardensPlannedSession" })),
    view(TodayDecision, decision, (v) => expect(v.refusal).toBe("HardensPlannedSession")),
    when(decision, new RecordDailyDecision(proposal())),
    then(decision, new DailyDecisionRecorded({ athleteId: anaId, day: today, attempt: 2, ...proposal() })),
    call(Planner.concretizeSession, { planId, day: today, workout, evidence: evidence("fp-1") }),
    succeed(Planner.concretizeSession, { accepted: true, reason: null }),
    then(decision, new PlanVerdictRecorded({ attempt: 2, accepted: true, reason: null })),
  ),
);

it.effect("only the athlete's device records their decisions", () =>
  story(as(bob), when(decision, new RecordDailyDecision(proposal())), rejected(new NotYours())),
);

const intent: Intent = {
  planId,
  summary: "Thursday: 45 minutes at most",
  limits: [{ day: Day.make("2026-11-12"), maxMinutes: 45, unavailable: false }],
};
const reply = {
  messageId: "m2",
  inReplyTo: "m1",
  text: "I'll keep Thursday to 45 minutes.",
  intent,
  model: "gpt-5.5",
  interpretedOn: "ios" as const,
};

it.effect("an intent changes the plan only after the athlete accepts it", () =>
  story(
    as(ana),
    when(thread, new SendMessage({ messageId: "m1", text: "Thursday I only have 45 minutes" })),
    then(thread, new MessageSent({ athleteId: anaId, messageId: "m1", text: "Thursday I only have 45 minutes" })),
    when(thread, new RecordCoachReply(reply)),
    then(thread, new CoachReplied(reply)),
    view(ConversationThread, thread, (v) => {
      expect(v.messages.map((m) => m.role)).toEqual(["athlete", "coach"]);
      expect(v.messages[1]?.intentStatus).toBe("proposed");
    }),
    when(thread, new AcceptIntent({ messageId: "m2" })),
    then(thread, new IntentAccepted({ messageId: "m2", intent })),
    call(Planner.reviseWeek, { planId, limits: intent.limits }),
    succeed(Planner.reviseWeek, { accepted: true, reason: null }),
    then(thread, new IntentApplied({ messageId: "m2" })),
    view(ConversationThread, thread, (v) => expect(v.messages[1]?.intentStatus).toBe("applied")),
    when(thread, new AcceptIntent({ messageId: "m2" })),
    rejected(new NoOpenIntent({ messageId: "m2" })),
  ),
);

it.effect("a dismissed intent never reaches the plan; a refused one keeps the reason", () =>
  story(
    given(thread, new CoachReplied(reply), new CoachReplied({ ...reply, messageId: "m3" })),
    as(ana),
    when(thread, new DismissIntent({ messageId: "m2" })),
    then(thread, new IntentDismissed({ messageId: "m2" })),
    when(thread, new AcceptIntent({ messageId: "m3" })),
    then(thread, new IntentAccepted({ messageId: "m3", intent })),
    call(Planner.reviseWeek, { planId, limits: intent.limits }),
    succeed(Planner.reviseWeek, { accepted: false, reason: "PlanNotActive" }),
    then(thread, new IntentRefused({ messageId: "m3", reason: "PlanNotActive" })),
  ),
);

const draft: PlanDraft = {
  athleteId: anaId,
  title: "Gran fondo build",
  goal: "event",
  objective: "Finish strong",
  rationale: "Eight weeks of base and build.",
  startDay: today,
  endDay: Day.make("2027-01-03"),
  phases: [{ focus: "base", startWeek: 1, endWeek: 4, summary: "Aerobic base" }],
  longRideWeekday: 1,
  event: null,
  sessions: [{ day: today, kind: "endurance", title: "Easy endurance", targetMinutes: 60, purpose: "Base" }],
};

it.effect("a consultation ends with a plan, or reopens with the plan's reason", () =>
  story(
    as(ana),
    when(consultation, new StartConsultation({})),
    then(consultation, new ConsultationStarted()),
    when(consultation, new RecordCoachQuestion({ text: "What's your goal?", model: "gpt-5.5", interpretedOn: "ios" })),
    when(consultation, new AnswerQuestion({ text: "A gran fondo in January" })),
    when(consultation, new AcceptDraft({ planId })),
    rejected(new NoDraft()),
    when(consultation, new RecordDraft({ draft, model: "gpt-5.5", interpretedOn: "ios" })),
    when(consultation, new AcceptDraft({ planId })),
    then(
      consultation,
      new CoachAsked({ text: "What's your goal?", model: "gpt-5.5", interpretedOn: "ios" }),
      new AthleteAnswered({ text: "A gran fondo in January" }),
      new DraftProposed({ draft, model: "gpt-5.5", interpretedOn: "ios" }),
      new DraftAccepted({ planId, draft }),
    ),
    call(Planner.createPlan, { planId, draft }),
    succeed(Planner.createPlan, { accepted: false, reason: "InvalidPlan" }),
    then(consultation, new DraftRefusedByPlan({ reason: "InvalidPlan" })),
    view(ConsultationView, consultation, (v) => expect(v).toMatchObject({ stage: "open", refusal: "InvalidPlan" })),
    when(consultation, new AcceptDraft({ planId })),
    then(consultation, new DraftAccepted({ planId, draft })),
    call(Planner.createPlan, { planId, draft }),
    succeed(Planner.createPlan, { accepted: true, reason: null }),
    then(consultation, new PlanCreatedFromDraft({ planId })),
  ),
);

it.effect("only one automatic profile generation, across every device", () =>
  story(
    as(ana),
    when(profile, new RecordProfileAttempt({ automatic: true })),
    then(profile, new ProfileAttempted({ automatic: true })),
    when(profile, new RecordProfileAttempt({ automatic: true })),
    rejected(new AutomaticAttemptUsed()),
    when(profile, new RecordProfileAttempt({ automatic: false })),
    then(profile, new ProfileAttempted({ automatic: false })),
  ),
);
