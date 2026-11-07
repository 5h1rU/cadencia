import * as Domain from "@alchemy.run/domain";
import { Coach } from "./Coach.model.ts";

/**
 * What the athlete's device reaches, published over HTTP at `/v1`: the
 * commands that record each AI interpretation (the device runs the AI), the
 * athlete's answers that need no AI, and the views the device caches. Today
 * that device is Cadencia iOS. Nothing else of the Coach is published to it.
 */
export class DeviceCoachApi extends Domain.Api("DeviceCoachApi", {
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
