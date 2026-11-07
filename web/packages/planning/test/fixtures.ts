import { EvidenceSnapshot } from "@cadencia/athlete/Evidence";
import { athlete } from "@cadencia/identity/Actor";
import { AthleteId } from "@cadencia/identity/Athlete.id";
import { Day } from "@cadencia/kernel/Calendar/Day";
import { Weekday } from "@cadencia/kernel/Calendar/Week";
import { EntityKey } from "@cadencia/kernel/EntityKey";
import { PlanId, planIdFor } from "@cadencia/kernel/Plan.id";
import { Paragraph, Title } from "@cadencia/kernel/Text";
import { Phase } from "@cadencia/kernel/Training/Phase";
import type { SessionKind } from "@cadencia/kernel/Training/SessionKind";
import { FtpFraction, Minutes } from "@cadencia/kernel/Training/Units";
import { type Workout, WorkoutStep } from "@cadencia/kernel/Training/Workout";
import * as Schema from "effect/Schema";
import { PlanCreated } from "../src/Plan/CreatePlan.command.ts";
import { Plan } from "../src/Plan/Plan.aggregate.ts";
import type { PlannedSession } from "../src/Plan/PlannedSession.ts";
import { ExternalId, externalIdFor, SessionId } from "../src/Plan/Session.id.ts";

/** Every fixture is decoded, so a fixture that breaks a rule fails here, not in a story. */
export const day = Schema.decodeUnknownSync(Day);
export const minutes = Schema.decodeUnknownSync(Minutes);
export const title = Schema.decodeUnknownSync(Title);
export const paragraph = Schema.decodeUnknownSync(Paragraph);
export const intensity = Schema.decodeUnknownSync(FtpFraction);
export const weekday = Schema.decodeUnknownSync(Weekday);
export const externalId = Schema.decodeUnknownSync(ExternalId);
export const sessionId = Schema.decodeUnknownSync(SessionId);

export const ana = athlete("i100");
export const bob = athlete("i200");
export const anaId = AthleteId.make("i100");
export const planKey = EntityKey.make("0b6f5a2e-1c3d-4e5f-8a9b-0c1d2e3f4a5b");
export const planId: PlanId = planIdFor(anaId, planKey);
export const plan = Plan.ref(planId);

export const monday = day("2026-11-09");
export const tuesday = day("2026-11-10");
export const saturday = day("2026-11-14");

export const session = (d: Day, kind: SessionKind, targetMinutes: number, name: string): PlannedSession => ({
  sessionId: sessionId(d),
  day: d,
  kind,
  title: title(name),
  targetMinutes: minutes(targetMinutes),
  purpose: paragraph(`${name} purpose`),
  status: "provisional",
  workout: null,
  externalId: externalIdFor(planId, sessionId(d)),
});

export const endurance = session(monday, "endurance", 60, "Easy endurance");
export const threshold = session(tuesday, "threshold", 75, "Threshold");
export const longRide = session(saturday, "longRide", 180, "Long ride");

export const basePhase = Schema.decodeUnknownSync(Phase)({ focus: "base", startWeek: 1, endWeek: 6, summary: "Aerobic base" });

export const planCreated = (
  sessions: ReadonlyArray<PlannedSession> = [endurance, threshold, longRide],
  objective: Paragraph | null = null,
) =>
  new PlanCreated({
    athleteId: anaId,
    title: title("Base block"),
    goal: "endurance",
    objective,
    startDay: monday,
    endDay: day("2026-12-20"),
    phases: [basePhase],
    longRideWeekday: weekday(7),
    event: null,
    sessions,
  });

export const steady = (name: string, mins: number, ftp: number): WorkoutStep =>
  Schema.decodeUnknownSync(WorkoutStep)({
    name,
    durationSeconds: mins * 60,
    startIntensity: ftp,
    endIntensity: ftp,
    cadenceRpm: null,
  });

export const workout = (kind: SessionKind, steps: ReadonlyArray<WorkoutStep>): Workout => ({
  name: title(kind),
  kind,
  steps,
  intensityCeiling: null,
  rationale: null,
});

export const easyHour = workout("endurance", [steady("Z2", 60, 0.65)]);
export const easyFortyFive = workout("endurance", [steady("Z2", 45, 0.65)]);
export const intervals = workout("threshold", [
  steady("Warm-up", 15, 0.6),
  steady("Threshold", 30, 0.98),
  steady("Cool-down", 15, 0.55),
]);

export const FINGERPRINT = "a".repeat(64);

export const evidence = (
  days: ReadonlyArray<{ day: string; maxMinutes?: number | null; unavailable?: boolean; hardOtherTraining?: boolean }> = [],
  eventDays: ReadonlyArray<string> = [],
): EvidenceSnapshot =>
  Schema.decodeUnknownSync(EvidenceSnapshot)({
    fingerprint: FINGERPRINT,
    readiness: { level: "normal", score: 60, summary: "Typical HRV and sleep." },
    days: days.map((d) => ({ maxMinutes: null, unavailable: false, hardOtherTraining: false, ...d })),
    eventDays,
  });
