import { describe, expect, it } from "@effect/vitest";
import { addDays, Day, daysBetween, weekdayOf } from "../src/Day.ts";
import { peakIntensity, totalMinutes, type Workout } from "../src/Workout.ts";

describe("days", () => {
  it("count across months and years", () => {
    expect(addDays(Day.make("2026-12-31"), 1)).toBe("2027-01-01");
    expect(addDays(Day.make("2026-03-01"), -1)).toBe("2026-02-28");
    expect(daysBetween(Day.make("2026-11-09"), Day.make("2026-11-16"))).toBe(7);
  });

  it("number weekdays as Intervals and iOS do: 1 is Sunday", () => {
    expect(weekdayOf(Day.make("2026-11-08"))).toBe(1);
    expect(weekdayOf(Day.make("2026-11-14"))).toBe(7);
  });

  it("reject anything that isn't YYYY-MM-DD", () => {
    expect(() => Day.make("9/11/2026")).toThrow();
  });
});

describe("workouts", () => {
  const workout: Workout = {
    name: "Ramp",
    kind: "tempo",
    rationale: "",
    steps: [
      { name: "Warm-up", durationSeconds: 600, startIntensity: 0.5, endIntensity: 0.7 },
      { name: "Tempo", durationSeconds: 1200, startIntensity: 0.85, endIntensity: 0.85 },
    ],
  };

  it("know their length and their hardest moment", () => {
    expect(totalMinutes(workout)).toBe(30);
    expect(peakIntensity(workout)).toBe(0.85);
  });
});
