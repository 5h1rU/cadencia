import { describe, expect, it } from "@effect/vitest";
import * as Option from "effect/Option";
import * as Schema from "effect/Schema";
import { AthleteId, keyOf, ownerOf } from "../src/Athlete.id.ts";

/** Each type, what it must accept and what it must refuse. */
const cases: ReadonlyArray<readonly [string, Schema.Top, ReadonlyArray<unknown>, ReadonlyArray<unknown>]> = [
  ["AthleteId", AthleteId, ["i1", "i393051"], ["", "393051", "i", "i0", "i12a", " i1"]],
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

describe("athlete-scoped ids", () => {
  it("name their owner before the first colon", () => {
    expect(ownerOf("i100:2026-11")).toBe("i100");
    expect(keyOf("i100:2026-11-09")).toBe("2026-11-09");
  });
});
