import { describe, expect, it } from "@effect/vitest";
import * as Option from "effect/Option";
import * as Schema from "effect/Schema";
import { PlanId } from "@cadencia/kernel/Plan.id";
import { ExternalId, externalIdFor, SessionId } from "../src/Plan/Session.id.ts";

const UUID = "0b6f5a2e-1c3d-4e5f-8a9b-0c1d2e3f4a5b";

/** Each type, what it must accept and what it must refuse. */
const cases: ReadonlyArray<readonly [string, Schema.Top, ReadonlyArray<unknown>, ReadonlyArray<unknown>]> = [
  ["SessionId", SessionId, ["2026-11-09"], ["s1", ""]],
  ["ExternalId", ExternalId, [`cadencia-i100-${UUID}-2026-11-09`], ["cadencia-i100-p1-2026-11-09", "other-app-1"]],
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

describe("sessions in Intervals.icu", () => {
  it("carry an external id built from the plan and the day", () => {
    expect(externalIdFor(PlanId.make(`i100:${UUID}`), SessionId.make("2026-11-09"))).toBe(`cadencia-i100-${UUID}-2026-11-09`);
  });
});
