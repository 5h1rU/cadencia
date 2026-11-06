import { describe, expect, it } from "@effect/vitest";
import * as Option from "effect/Option";
import * as Schema from "effect/Schema";
import { IntervalsActivityId } from "../src/Activity.id.ts";
import { Fingerprint } from "../src/Evidence.ts";
import { Bpm, FtpWatts, HrvMs, Kilograms, Rpe, TrainingLoad, Watts, WellnessScale } from "../src/Measures.ts";
import { ReadinessScore } from "../src/Readiness.ts";

/** Each type, what it must accept and what it must refuse. */
const cases: ReadonlyArray<readonly [string, Schema.Top, ReadonlyArray<unknown>, ReadonlyArray<unknown>]> = [
  ["IntervalsActivityId", IntervalsActivityId, ["i12345678", "123"], ["", "a b"]],
  ["Fingerprint", Fingerprint, ["a".repeat(64)], ["fp-1", "A".repeat(64), "a".repeat(63)]],
  ["FtpWatts", FtpWatts, [30, 198, 700], [29, 701, 198.5]],
  ["Watts", Watts, [0, 250.5], [-1, 3001]],
  ["Kilograms", Kilograms, [20, 74.1], [19.9, 351]],
  ["Bpm", Bpm, [49, 201], [19, 251]],
  ["HrvMs", HrvMs, [0, 65.2], [-1, 501]],
  ["TrainingLoad", TrainingLoad, [0, 85.3], [-1, 2001]],
  ["ReadinessScore", ReadinessScore, [0, 100], [-1, 101, 50.5]],
  ["WellnessScale", WellnessScale, [1, 4], [0, 5, 2.5]],
  ["Rpe", Rpe, [1, 10], [0, 11]],
];

describe("the schema catalog", () => {
  for (const [name, schema, valid, invalid] of cases) {
    const decode = Schema.decodeUnknownOption(schema as Schema.Codec<unknown, unknown>);
    it(`${name} accepts what it names`, () => {
      for (const value of valid) expect(Option.isSome(decode(value)), `${name} should accept ${JSON.stringify(value)}`).toBe(true);
    });
    it(`${name} refuses what it doesn't`, () => {
      for (const value of invalid) expect(Option.isNone(decode(value)), `${name} should refuse ${JSON.stringify(value)}`).toBe(true);
    });
  }
});
