import * as Domain from "@alchemy.run/domain";
import { Coach } from "./Coach.model.ts";

/** What any of the athlete's clients reaches: the coach's memory, and answers that need no AI. */
export class AthleteCoachApi extends Domain.Api("AthleteCoachApi", {
  model: Coach,
  commands: ["AcceptIntent", "DismissIntent", "DismissFtpProposal"],
  views: ["TodayDecision", "ConversationThread", "ConsultationView", "RiderProfileCard", "CoachTimeline"],
  streams: [],
}) {}
