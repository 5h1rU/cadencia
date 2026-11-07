import { EvidenceSnapshot } from "@cadencia/athlete/Evidence";
import { FtpWatts } from "@cadencia/athlete/Measures";
import { athlete } from "@cadencia/identity/Actor";
import { AthleteId } from "@cadencia/identity/Athlete.id";
import { Day } from "@cadencia/kernel/Calendar/Day";
import { EntityKey } from "@cadencia/kernel/EntityKey";
import { planIdFor } from "@cadencia/kernel/Plan.id";
import { DayLimit } from "@cadencia/kernel/Training/DayLimit";
import { Workout } from "@cadencia/kernel/Training/Workout";
import * as Schema from "effect/Schema";
import { CoachNote, type Refusal } from "../src/CoachShape.ts";
import { MessageText, ModelName } from "../src/CoachText.ts";
import { consultationIdFor } from "../src/Consultation/Consultation.id.ts";
import { PlanDraft } from "../src/Consultation/PlanDraft.ts";
import { conversationIdFor, YearMonth } from "../src/Conversation/Conversation.id.ts";
import { Intent } from "../src/Conversation/Intent.ts";
import { MessageId } from "../src/Conversation/Message.id.ts";
import { dailyDecisionIdFor } from "../src/DailyDecision/DailyDecision.id.ts";

/** Every fixture is decoded, so a fixture that breaks a rule fails here, not in a story. */
export const day = Schema.decodeUnknownSync(Day);
export const text = Schema.decodeUnknownSync(MessageText);
export const messageId = Schema.decodeUnknownSync(MessageId);
export const ftp = Schema.decodeUnknownSync(FtpWatts);

export const ana = athlete("i100");
export const bob = athlete("i200");
export const anaId = AthleteId.make("i100");
export const today = day("2026-11-09");
export const planId = planIdFor(anaId, EntityKey.make("0b6f5a2e-1c3d-4e5f-8a9b-0c1d2e3f4a5b"));
export const decisionId = dailyDecisionIdFor(anaId, today);
export const conversationId = conversationIdFor(anaId, YearMonth.make("2026-11"));
export const consultationId = consultationIdFor(anaId, EntityKey.make("7c9e6679-7425-40de-944b-e07fc1f90ae7"));
export const model = ModelName.make("gpt-5.5");

export const workout = Schema.decodeUnknownSync(Workout)({
  name: "Easy endurance",
  kind: "endurance",
  intensityCeiling: null,
  rationale: "HRV is typical; keep the plan's aerobic day.",
  steps: [{ name: "Z2", durationSeconds: 3600, startIntensity: 0.65, endIntensity: 0.65, cadenceRpm: null }],
});

export const note = Schema.decodeUnknownSync(CoachNote)({
  headline: "Easy endurance",
  body: "Your body is ready.",
  session: "One hour in Z2.",
  watch: null,
});

export const fingerprintA = "a".repeat(64);

export const evidence = (fingerprint = fingerprintA): EvidenceSnapshot =>
  Schema.decodeUnknownSync(EvidenceSnapshot)({
    fingerprint,
    readiness: { level: "normal", score: 60, summary: "Typical HRV and sleep." },
    days: [],
    eventDays: [],
  });

export const proposal = (fingerprint = fingerprintA) => ({
  planId,
  workout,
  note,
  evidence: evidence(fingerprint),
  model,
  interpretedOn: "ios" as const,
});

export const intent = Schema.decodeUnknownSync(Intent)({
  planId,
  summary: "Thursday: 45 minutes at most",
  limits: [{ day: "2026-11-12", maxMinutes: 45, unavailable: false }],
});
export const limits = intent.limits.map((l) => Schema.decodeUnknownSync(DayLimit)(l));

export const draft = Schema.decodeUnknownSync(PlanDraft)({
  title: "Gran fondo build",
  goal: "event",
  objective: "Finish strong",
  rationale: "Eight weeks of base and build.",
  startDay: "2026-11-09",
  endDay: "2027-01-03",
  phases: [{ focus: "base", startWeek: 1, endWeek: 4, summary: "Aerobic base" }],
  longRideWeekday: 1,
  event: null,
  sessions: [{ day: "2026-11-09", kind: "endurance", title: "Easy endurance", targetMinutes: 60, purpose: "Base" }],
});

export const hardens: Refusal = { reason: "hardensPlan", detail: null };
