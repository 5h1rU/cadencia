import { athlete } from "@cadencia/kernel/Actor";
import { AthleteId } from "@cadencia/kernel/Athlete.id";
import { Day } from "@cadencia/kernel/Day";
import { type DayConditions, type EvidenceSnapshot, Fingerprint } from "@cadencia/kernel/Evidence";
import type { SessionKind } from "@cadencia/kernel/SessionKind";
import type { Workout, WorkoutStep } from "@cadencia/kernel/Workout";
import { PlanCreated } from "../src/Plan/CreatePlan.command.ts";
import { Plan } from "../src/Plan/Plan.aggregate.ts";
import { externalIdFor, type PlannedSession } from "../src/Plan/PlanShape.ts";

export const ana = athlete("i100");
export const bob = athlete("i200");
export const anaId = AthleteId.make("i100");
export const planId = "i100:p1";
export const plan = Plan.ref(planId);

export const day = (iso: string) => Day.make(iso);
export const monday = day("2026-11-09");
export const tuesday = day("2026-11-10");
export const saturday = day("2026-11-14");

export const session = (d: Day, kind: SessionKind, targetMinutes: number, title: string = kind): PlannedSession => ({
  sessionId: d,
  day: d,
  kind,
  title,
  targetMinutes,
  purpose: `${title} purpose`,
  status: "provisional",
  workout: null,
  externalId: externalIdFor(planId, d),
});

export const endurance = session(monday, "endurance", 60, "Easy endurance");
export const threshold = session(tuesday, "threshold", 75, "Threshold");
export const longRide = session(saturday, "longRide", 180, "Long ride");

export const planCreated = (sessions: ReadonlyArray<PlannedSession> = [endurance, threshold, longRide]) =>
  new PlanCreated({
    athleteId: anaId,
    title: "Base block",
    goal: "endurance",
    startDay: monday,
    endDay: day("2026-12-20"),
    phases: [{ focus: "base", startWeek: 1, endWeek: 6, summary: "Aerobic base" }],
    longRideWeekday: 7,
    event: null,
    sessions,
  });

export const steady = (name: string, minutes: number, intensity: number): WorkoutStep => ({
  name,
  durationSeconds: minutes * 60,
  startIntensity: intensity,
  endIntensity: intensity,
});

export const workout = (kind: SessionKind, steps: ReadonlyArray<WorkoutStep>): Workout => ({
  name: kind,
  kind,
  steps,
  rationale: "test",
});

export const easyHour = workout("endurance", [steady("Z2", 60, 0.65)]);
export const easyFortyFive = workout("endurance", [steady("Z2", 45, 0.65)]);
export const intervals = workout("threshold", [
  steady("Warm-up", 15, 0.6),
  steady("Threshold", 30, 0.98),
  steady("Cool-down", 15, 0.55),
]);

export const evidence = (days: ReadonlyArray<Partial<DayConditions> & { day: Day }> = []): EvidenceSnapshot => ({
  fingerprint: Fingerprint.make("fp-1"),
  readiness: { level: "normal", score: 60, summary: "Typical HRV and sleep." },
  days: days.map((d) => ({ maxMinutes: null, unavailable: false, hardOtherTraining: false, ...d })),
  eventDays: [],
});
