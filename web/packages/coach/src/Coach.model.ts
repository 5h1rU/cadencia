import * as Domain from "@alchemy.run/domain";
import * as Layer from "effect/Layer";
import { CoachTimeline } from "./CoachTimeline.view.ts";
import { Consultation } from "./Consultation/Consultation.aggregate.ts";
import { ConsultationView } from "./Consultation/ConsultationView.view.ts";
import { PlanFromConsultation, PlanFromConsultationLive } from "./Consultation/PlanFromConsultation.policy.ts";
import { Conversation } from "./Conversation/Conversation.aggregate.ts";
import { ConversationThread } from "./Conversation/ConversationThread.view.ts";
import { IntentApplier, IntentApplierLive } from "./Conversation/IntentApplier.policy.ts";
import { DailyDecision } from "./DailyDecision/DailyDecision.aggregate.ts";
import { DecisionToPlan, DecisionToPlanLive } from "./DailyDecision/DecisionToPlan.policy.ts";
import { TodayDecision } from "./DailyDecision/TodayDecision.view.ts";
import { RiderProfile } from "./RiderProfile/RiderProfile.aggregate.ts";
import { RiderProfileCard } from "./RiderProfile/RiderProfileCard.view.ts";

/**
 * The coach's memory: what the AI interpreted, with its provenance, and what
 * the plan did with it. The AI runs outside this model; it only records.
 */
export class Coach extends Domain.Model("Coach", {
  aggregates: [DailyDecision, Conversation, Consultation, RiderProfile],
  views: [TodayDecision, ConversationThread, ConsultationView, RiderProfileCard, CoachTimeline],
  policies: [DecisionToPlan, IntentApplier, PlanFromConsultation],
}) {}

/** The policies' implementations. They require the `Planner` external system. */
export const CoachHandlers = Layer.mergeAll(DecisionToPlanLive, IntentApplierLive, PlanFromConsultationLive);
