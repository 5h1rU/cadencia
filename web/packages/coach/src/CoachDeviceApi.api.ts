import * as Domain from "@alchemy.run/domain";
import { Coach } from "./Coach.model.ts";

/**
 * What the device that runs the AI reaches: the commands that record each
 * interpretation. Today that device is Cadencia iOS.
 */
export class CoachDeviceApi extends Domain.Api("CoachDeviceApi", {
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
  ],
  views: [],
  streams: [],
}) {}
