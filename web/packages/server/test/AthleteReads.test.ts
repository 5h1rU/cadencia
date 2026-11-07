import { ActivitySummary } from "@cadencia/athlete/ActivitySummary";
import { WellnessScale } from "@cadencia/athlete/Measures";
import { WellnessDay } from "@cadencia/athlete/Wellness";
import { Day } from "@cadencia/kernel/Calendar/Day";
import { Paragraph } from "@cadencia/kernel/Text";
import { describe, expect, it } from "@effect/vitest";
import * as Option from "effect/Option";
import * as Schema from "effect/Schema";
import {
  activityFromIntervals,
  measuresFromIntervals,
  rowsFromIntervals,
  wellnessFromIntervals,
  wellnessForIntervals,
} from "../src/Intervals/AthleteReads.ts";

describe("Intervals activities, at the edge", () => {
  it("become Cadencia's activity summaries, in Cadencia's names and units", () => {
    const activity = activityFromIntervals({
      id: "i12345678",
      name: "  Morning ride ",
      type: "Ride",
      start_date_local: "2026-11-05T07:30:00",
      moving_time: 3600,
      distance: 32_500,
      icu_training_load: 62.4,
      icu_average_watts: 180,
      icu_weighted_avg_watts: 195,
      average_heartrate: 141,
      icu_rpe: 6,
      paired_event_id: 77,
    });
    expect(Option.getOrNull(activity)).toEqual({
      activityId: "i12345678",
      day: "2026-11-05",
      name: "Morning ride",
      movingTime: 3600,
      distance: 32.5,
      trainingLoad: 62.4,
      averagePower: 180,
      normalizedPower: 195,
      averageHeartRate: 141,
      rpe: 6,
    });
    // What leaves the server is exactly what the app decodes.
    expect(Option.isSome(Schema.decodeUnknownOption(ActivitySummary)(Option.getOrThrow(activity)))).toBe(true);
  });

  it("keep the row when a field is missing or unusable, with that field null", () => {
    const activity = Option.getOrThrow(
      activityFromIntervals({
        id: "i1",
        name: "",
        start_date_local: "yesterday",
        moving_time: -5,
        icu_training_load: "high",
        icu_weighted_avg_watts: 9999,
        average_heartrate: null,
        icu_rpe: 11,
      }),
    );
    expect(activity).toEqual({
      activityId: "i1",
      day: null,
      name: null,
      movingTime: null,
      distance: null,
      trainingLoad: null,
      averagePower: null,
      normalizedPower: null,
      averageHeartRate: null,
      rpe: null,
    });
  });

  it("drop a row without an id Cadencia can name it by", () => {
    expect(Option.isNone(activityFromIntervals({ name: "No id", moving_time: 60 }))).toBe(true);
    expect(Option.isNone(activityFromIntervals({ id: "has spaces" }))).toBe(true);
    expect(Option.isNone(activityFromIntervals(null))).toBe(true);
    expect(rowsFromIntervals([{ id: "i1" }, { name: "x" }, "junk", { id: "i2" }], activityFromIntervals).map((a) => a.activityId)).toEqual([
      "i1",
      "i2",
    ]);
  });

  it("read nothing from an answer that is not a list", () => {
    expect(rowsFromIntervals({ error: "nope" }, activityFromIntervals)).toEqual([]);
  });
});

describe("Intervals wellness, at the edge", () => {
  it("becomes Cadencia's wellness days", () => {
    const day = Option.getOrThrow(
      wellnessFromIntervals({
        id: "2026-11-05",
        ctl: 54.2,
        atl: 61.9,
        weight: 74.1,
        restingHR: 48,
        hrv: 65.2,
        sleepSecs: 27_000,
        sleepQuality: 2,
        soreness: 3,
        fatigue: 2,
        stress: 1,
        mood: 2,
        motivation: 1,
        injury: null,
        comments: " Legs heavy ",
        readiness: 70,
      }),
    );
    expect(day).toEqual({
      day: "2026-11-05",
      fitness: 54.2,
      acuteLoad: 61.9,
      weight: 74.1,
      restingHeartRate: 48,
      hrv: 65.2,
      sleep: 27_000,
      sleepQuality: 2,
      soreness: 3,
      fatigue: 2,
      stress: 1,
      mood: 2,
      motivation: 1,
      injury: null,
      comments: "Legs heavy",
    });
    expect(Option.isSome(Schema.decodeUnknownOption(WellnessDay)(day))).toBe(true);
  });

  it("nulls values outside Cadencia's ranges and drops days that don't exist", () => {
    const day = Option.getOrThrow(wellnessFromIntervals({ id: "2026-11-05", weight: 7, mood: 5, ctl: -1 }));
    expect([day.weight, day.mood, day.fitness]).toEqual([null, null, null]);
    expect(Option.isNone(wellnessFromIntervals({ id: "2026-02-30", ctl: 50 }))).toBe(true);
    expect(Option.isNone(wellnessFromIntervals({ ctl: 50 }))).toBe(true);
  });

  it("sends a declaration under the day's id", () => {
    expect(wellnessForIntervals(Day.make("2026-11-05"), { mood: WellnessScale.make(3), comments: Paragraph.make("Fine") })).toEqual({
      id: "2026-11-05",
      mood: 3,
      comments: "Fine",
    });
  });
});

describe("the athlete's Intervals record, at the edge", () => {
  it("gives the name, weight and Ride FTP", () => {
    expect(
      measuresFromIntervals({
        name: "Ana",
        icu_weight: 61.5,
        sportSettings: [
          { types: ["Run"], ftp: 300 },
          { types: ["Ride", "VirtualRide"], ftp: 230 },
        ],
      }),
    ).toEqual({ name: "Ana", weight: 61.5, ftp: 230 });
  });

  it("leaves out what it can't use", () => {
    expect(measuresFromIntervals({ name: 42, weight: 1000, sportSettings: "none" })).toEqual({ name: null, weight: null, ftp: null });
    expect(measuresFromIntervals(undefined)).toEqual({ name: null, weight: null, ftp: null });
  });
});
