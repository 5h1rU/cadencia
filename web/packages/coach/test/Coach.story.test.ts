import { Fingerprint } from "@cadencia/athlete/Evidence";
import type { Actor } from "@cadencia/identity/Actor";
import { CurrentActor } from "@cadencia/identity/CurrentActor.context";
import { NotYours } from "@cadencia/identity/NotYours.rejection";
import { Story } from "@alchemy.run/domain/Story";
import { expect, it } from "@effect/vitest";
import * as Schema from "effect/Schema";
import { Coach, CoachHandlers } from "../src/Coach.model.ts";
import { CoachTimeline } from "../src/CoachTimeline.view.ts";
import { AcceptDraft, DraftAccepted, NoDraft } from "../src/Consultation/AcceptDraft.command.ts";
import { AnswerQuestion, AthleteAnswered } from "../src/Consultation/AnswerQuestion.command.ts";
import { Consultation } from "../src/Consultation/Consultation.aggregate.ts";
import { ConsultationView } from "../src/Consultation/ConsultationView.view.ts";
import { CoachAsked, RecordCoachQuestion } from "../src/Consultation/RecordCoachQuestion.command.ts";
import { DraftProposed, RecordDraft } from "../src/Consultation/RecordDraft.command.ts";
import { DraftRefusedByPlan, PlanCreatedFromDraft } from "../src/Consultation/RecordPlanCreation.command.ts";
import { ConsultationNotOpen } from "../src/Consultation/ConsultationNotOpen.rejection.ts";
import {
  ConsultationAlreadyStarted,
  ConsultationStarted,
  StartConsultation,
} from "../src/Consultation/StartConsultation.command.ts";
import { AcceptIntent, IntentAccepted } from "../src/Conversation/AcceptIntent.command.ts";
import { Conversation } from "../src/Conversation/Conversation.aggregate.ts";
import { ConversationThread } from "../src/Conversation/ConversationThread.view.ts";
import { DismissIntent, IntentDismissed } from "../src/Conversation/DismissIntent.command.ts";
import { NoOpenIntent } from "../src/Conversation/NoOpenIntent.rejection.ts";
import { CoachReplied, RecordCoachReply } from "../src/Conversation/RecordCoachReply.command.ts";
import { IntentApplied, IntentRefused } from "../src/Conversation/RecordIntentOutcome.command.ts";
import { MessageSent, SendMessage } from "../src/Conversation/SendMessage.command.ts";
import { Attempt } from "../src/Counts.ts";
import { DailyDecision } from "../src/DailyDecision/DailyDecision.aggregate.ts";
import {
  DailyDecisionRecorded,
  DecisionAlreadyAccepted,
  RecordDailyDecision,
} from "../src/DailyDecision/RecordDailyDecision.command.ts";
import { PlanVerdictRecorded } from "../src/DailyDecision/RecordPlanVerdict.command.ts";
import { TodayDecision } from "../src/DailyDecision/TodayDecision.view.ts";
import { Planner, PlannerRequestId } from "../src/Planner.external.ts";
import {
  AutomaticAttemptUsed,
  ProfileAttempted,
  RecordProfileAttempt,
} from "../src/RiderProfile/RecordProfileAttempt.command.ts";
import { DismissFtpProposal } from "../src/RiderProfile/DismissFtpProposal.command.ts";
import { RecordProfile } from "../src/RiderProfile/RecordProfile.command.ts";
import { RiderProfile } from "../src/RiderProfile/RiderProfile.aggregate.ts";
import { RiderReport } from "../src/RiderProfile/RiderReport.ts";
import {
  ana,
  anaId,
  bob,
  consultationId,
  conversationId,
  decisionId,
  draft,
  evidence,
  fingerprintA,
  ftp,
  hardens,
  intent,
  messageId,
  model,
  note,
  planId,
  proposal,
  text,
  today,
  workout,
} from "./fixtures.ts";

const { call, emitted, given, provide, rejected, succeed, then, view, when } = Story;
const as = (actor: Actor) => provide(CurrentActor, actor);
const story = Story.make(Coach, { layer: CoachHandlers, stub: [Planner] });

const decision = DailyDecision.ref(decisionId);
const thread = Conversation.ref(conversationId);
const consultation = Consultation.ref(consultationId);
const profile = RiderProfile.ref(anaId);
const accepted = { _tag: "Accepted" as const };
const refused = { _tag: "Refused" as const, refusal: hardens };
const request = (stream: string, seq: number) => PlannerRequestId.make(`${stream}:${seq}`);
const first = Attempt.make(1);
const second = Attempt.make(2);

it.effect("the day's decision goes to the plan, and its answer is recorded", () =>
  story(
    as(ana),
    when(decision, new RecordDailyDecision(proposal())),
    then(decision, new DailyDecisionRecorded({ athleteId: anaId, day: today, attempt: first, ...proposal() })),
    call(Planner.concretizeSession, {
      requestId: request(`DailyDecision/${decisionId}`, 1),
      planId,
      day: today,
      workout,
      evidence: evidence(),
    }),
    succeed(Planner.concretizeSession, { answer: accepted }),
    then(decision, new PlanVerdictRecorded({ attempt: first, answer: accepted })),
    view(TodayDecision, decision, (v) => {
      expect(v.status).toBe("accepted");
      expect(v.interpretedOn).toBe("ios");
    }),
    when(decision, new RecordDailyDecision(proposal())),
    rejected(new DecisionAlreadyAccepted({ fingerprint: Fingerprint.make(fingerprintA) })),
    emitted(CoachTimeline, anaId, [
      { entry: { _tag: "Decision", headline: note.headline } },
      { entry: { _tag: "Accepted" } },
    ]),
  ),
);

it.effect("a refused decision keeps the plan's reason, and can be tried again", () =>
  story(
    as(ana),
    when(decision, new RecordDailyDecision(proposal())),
    then(decision, new DailyDecisionRecorded({ athleteId: anaId, day: today, attempt: first, ...proposal() })),
    call(Planner.concretizeSession, {
      requestId: request(`DailyDecision/${decisionId}`, 1),
      planId,
      day: today,
      workout,
      evidence: evidence(),
    }),
    succeed(Planner.concretizeSession, { answer: refused }),
    then(decision, new PlanVerdictRecorded({ attempt: first, answer: refused })),
    view(TodayDecision, decision, (v) => expect(v.refusal).toEqual(hardens)),
    when(decision, new RecordDailyDecision(proposal())),
    then(decision, new DailyDecisionRecorded({ athleteId: anaId, day: today, attempt: second, ...proposal() })),
    call(Planner.concretizeSession, {
      requestId: request(`DailyDecision/${decisionId}`, 3),
      planId,
      day: today,
      workout,
      evidence: evidence(),
    }),
    succeed(Planner.concretizeSession, { answer: accepted }),
    then(decision, new PlanVerdictRecorded({ attempt: second, answer: accepted })),
  ),
);

it.effect("only the athlete's device records their decisions", () =>
  story(as(bob), when(decision, new RecordDailyDecision(proposal())), rejected(new NotYours())),
);

const asked = messageId("3f2b8c1e-9d4a-4b6f-8e2c-1a7d5f9b3c60");
const answered = messageId("8d7e6f5a-4b3c-4d2e-9f1a-0b9c8d7e6f5a");
const later = messageId("5a6b7c8d-9e0f-4a1b-8c2d-3e4f5a6b7c8d");
const reply = (id = answered) => ({
  messageId: id,
  inReplyTo: asked,
  text: text("I'll keep Thursday to 45 minutes."),
  intent,
  model,
  note,
  interpretedOn: "ios" as const,
});

it.effect("an intent changes the plan only after the athlete accepts it", () =>
  story(
    as(ana),
    when(thread, new SendMessage({ messageId: asked, text: text("Thursday I only have 45 minutes") })),
    then(thread, new MessageSent({ athleteId: anaId, messageId: asked, text: text("Thursday I only have 45 minutes") })),
    when(thread, new RecordCoachReply(reply())),
    then(thread, new CoachReplied(reply())),
    view(ConversationThread, thread, (v) => {
      expect(v.messages.map((m) => m.role)).toEqual(["athlete", "coach"]);
      expect(v.messages[1]?.intentStatus).toBe("proposed");
    }),
    when(thread, new AcceptIntent({ messageId: answered })),
    then(thread, new IntentAccepted({ messageId: answered, intent })),
    call(Planner.reviseWeek, { requestId: request(`Conversation/${conversationId}`, 3), planId, limits: intent.limits }),
    succeed(Planner.reviseWeek, { answer: accepted }),
    then(thread, new IntentApplied({ messageId: answered })),
    view(ConversationThread, thread, (v) => expect(v.messages[1]?.intentStatus).toBe("applied")),
    when(thread, new AcceptIntent({ messageId: answered })),
    rejected(new NoOpenIntent({ messageId: answered })),
  ),
);

it.effect("a dismissed intent never reaches the plan; a refused one keeps the reason", () =>
  story(
    given(thread, new CoachReplied(reply()), new CoachReplied(reply(later))),
    as(ana),
    when(thread, new DismissIntent({ messageId: answered })),
    then(thread, new IntentDismissed({ messageId: answered })),
    when(thread, new AcceptIntent({ messageId: later })),
    then(thread, new IntentAccepted({ messageId: later, intent })),
    call(Planner.reviseWeek, { requestId: request(`Conversation/${conversationId}`, 4), planId, limits: intent.limits }),
    succeed(Planner.reviseWeek, { answer: { _tag: "Refused", refusal: { reason: "planNotActive", detail: null } } }),
    then(thread, new IntentRefused({ messageId: later, refusal: { reason: "planNotActive", detail: null } })),
  ),
);

it.effect("a consultation ends with a plan, or reopens with the plan's reason", () => {
  const question = { text: text("What's your goal?"), model, interpretedOn: "ios" as const };
  const invalid = { reason: "invalidPlan" as const, detail: null };
  return story(
    as(ana),
    when(consultation, new StartConsultation({})),
    then(consultation, new ConsultationStarted()),
    when(consultation, new RecordCoachQuestion(question)),
    when(consultation, new AnswerQuestion({ text: text("A gran fondo in January") })),
    when(consultation, new AcceptDraft({ planId })),
    rejected(new NoDraft()),
    when(consultation, new RecordDraft({ draft, model, interpretedOn: "ios" })),
    when(consultation, new AcceptDraft({ planId })),
    then(
      consultation,
      new CoachAsked(question),
      new AthleteAnswered({ text: text("A gran fondo in January") }),
      new DraftProposed({ draft, model, interpretedOn: "ios" }),
      new DraftAccepted({ planId, draft }),
    ),
    call(Planner.createPlan, { requestId: request(`Consultation/${consultationId}`, 5), planId, draft }),
    succeed(Planner.createPlan, { answer: { _tag: "Refused", refusal: invalid } }),
    then(consultation, new DraftRefusedByPlan({ refusal: invalid })),
    view(ConsultationView, consultation, (v) => expect(v).toMatchObject({ stage: "open", refusal: invalid })),
    when(consultation, new AcceptDraft({ planId })),
    then(consultation, new DraftAccepted({ planId, draft })),
    call(Planner.createPlan, { requestId: request(`Consultation/${consultationId}`, 7), planId, draft }),
    succeed(Planner.createPlan, { answer: accepted }),
    then(consultation, new PlanCreatedFromDraft({ planId })),
  );
});

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

it.effect("a consultation starts once and takes questions, answers and drafts only while open", () => {
  const question = { text: text("What's your goal?"), model, interpretedOn: "ios" as const };
  return story(
    as(ana),
    when(consultation, new AnswerQuestion({ text: text("A gran fondo") })),
    rejected(new ConsultationNotOpen()),
    when(consultation, new RecordCoachQuestion(question)),
    rejected(new ConsultationNotOpen()),
    when(consultation, new StartConsultation({})),
    then(consultation, new ConsultationStarted()),
    when(consultation, new StartConsultation({})),
    rejected(new ConsultationAlreadyStarted()),
    when(consultation, new RecordDraft({ draft, model, interpretedOn: "ios" })),
    when(consultation, new AcceptDraft({ planId })),
    call(Planner.createPlan, { requestId: request(`Consultation/${consultationId}`, 3), planId, draft }),
    succeed(Planner.createPlan, { answer: accepted }),
    then(
      consultation,
      new DraftProposed({ draft, model, interpretedOn: "ios" }),
      new DraftAccepted({ planId, draft }),
      new PlanCreatedFromDraft({ planId }),
    ),
    when(consultation, new AnswerQuestion({ text: text("One more thing") })),
    rejected(new ConsultationNotOpen()),
    when(consultation, new RecordDraft({ draft, model, interpretedOn: "ios" })),
    rejected(new ConsultationNotOpen()),
    when(consultation, new AcceptDraft({ planId })),
    rejected(new ConsultationNotOpen()),
  );
});

it.effect("only the athlete works on their consultation", () =>
  story(
    as(bob),
    when(consultation, new StartConsultation({})),
    rejected(new NotYours()),
    given(consultation, new ConsultationStarted(), new DraftProposed({ draft, model, interpretedOn: "ios" })),
    when(consultation, new RecordCoachQuestion({ text: text("What's your goal?"), model, interpretedOn: "ios" })),
    rejected(new NotYours()),
    when(consultation, new AnswerQuestion({ text: text("A gran fondo") })),
    rejected(new NotYours()),
    when(consultation, new RecordDraft({ draft, model, interpretedOn: "ios" })),
    rejected(new NotYours()),
    when(consultation, new AcceptDraft({ planId })),
    rejected(new NotYours()),
  ),
);

it.effect("only the athlete talks with their coach, and an intent is settled once", () =>
  story(
    as(bob),
    when(thread, new SendMessage({ messageId: asked, text: text("Hi") })),
    rejected(new NotYours()),
    when(thread, new RecordCoachReply(reply())),
    rejected(new NotYours()),
    given(thread, new CoachReplied(reply())),
    when(thread, new AcceptIntent({ messageId: answered })),
    rejected(new NotYours()),
    when(thread, new DismissIntent({ messageId: answered })),
    rejected(new NotYours()),
    as(ana),
    when(thread, new DismissIntent({ messageId: answered })),
    then(thread, new IntentDismissed({ messageId: answered })),
    when(thread, new DismissIntent({ messageId: answered })),
    rejected(new NoOpenIntent({ messageId: answered })),
  ),
);

it.effect("only the athlete's device builds their rider profile", () => {
  const report = Schema.decodeUnknownSync(RiderReport)({
    riderType: "endurance",
    confidence: "moderate",
    headline: "Steady endurance rider",
    summary: "Long rides at an even pace.",
    strengths: ["Pacing"],
    development: ["Short efforts"],
    evidence: ["Twelve long rides"],
    caveats: [],
    oldest: "2026-08-01",
    newest: "2026-11-08",
    rideCount: 40,
  });
  return story(
    as(bob),
    when(profile, new RecordProfileAttempt({ automatic: false })),
    rejected(new NotYours()),
    when(profile, new RecordProfile({ report, model, interpretedOn: "ios" })),
    rejected(new NotYours()),
    when(profile, new DismissFtpProposal({ ftp: ftp(250) })),
    rejected(new NotYours()),
  );
});
