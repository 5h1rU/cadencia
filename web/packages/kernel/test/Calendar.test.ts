import { describe, expect, it } from "@effect/vitest";
import * as Schema from "effect/Schema";
import { addDays, Day, daysBetween } from "../src/Calendar/Day.ts";
import { weekdayOf } from "../src/Calendar/Week.ts";
import { peakIntensity, totalMinutes, Workout } from "../src/Training/Workout.ts";

const day = Schema.decodeUnknownSync(Day);

describe("days", () => {
  it("count across months and years", () => {
    expect(addDays(day("2026-12-31"), 1)).toBe("2027-01-01");
    expect(addDays(day("2026-03-01"), -1)).toBe("2026-02-28");
    expect(daysBetween(day("2026-11-09"), day("2026-11-16"))).toBe(7);
  });

  it("number weekdays as Intervals and iOS do: 1 is Sunday", () => {
    expect(weekdayOf(day("2026-11-08"))).toBe(1);
    expect(weekdayOf(day("2026-11-14"))).toBe(7);
  });
});

describe("workouts", () => {
  const workout = Schema.decodeUnknownSync(Workout)({
    name: "Ramp",
    kind: "tempo",
    rationale: null,
    intensityCeiling: null,
    steps: [
      { name: "Warm-up", durationSeconds: 600, startIntensity: 0.5, endIntensity: 0.7, cadenceRpm: null },
      { name: "Tempo", durationSeconds: 1200, startIntensity: 0.85, endIntensity: 0.85, cadenceRpm: 90 },
    ],
  });

  it("know their length and their hardest moment", () => {
    expect(totalMinutes(workout)).toBe(30);
    expect(peakIntensity(workout)).toBe(0.85);
  });
});
