import * as Domain from "@alchemy.run/domain";
import { Coach } from "./Coach.model.ts";

/**
 * What Cadencia iOS reaches, published over HTTP at `/v1`: the commands that
 * record each AI interpretation (iOS is the device that runs the AI), the
 * athlete's answers that need no AI, and the views iOS caches. Nothing else
 * of the Coach is published to it.
 */
export class IosCoachApi extends Domain.Api("IosCoachApi", {
  model: Coach,
  commands: [
    "RecordDailyDecision",
    "SendMessage",
    "RecordCoachReply",
    "StartConsultation",
    "RecordCoachQuestion",
    "AnswerQuestion",
    "RecordDraft",
    "AcceptDraft",
    "RecordProfileAttempt",
    "RecordProfile",
    "AcceptIntent",
    "DismissIntent",
    "DismissFtpProposal",
  ],
  views: ["TodayDecision", "ConversationThread", "ConsultationView", "RiderProfileCard"],
  streams: [],
}) {}
