import { describe, expect, it } from "@effect/vitest";
import * as Option from "effect/Option";
import * as Schema from "effect/Schema";
import { Day } from "../src/Calendar/Day.ts";
import { Weekday, WeekNumber } from "../src/Calendar/Week.ts";
import { EntityKey } from "../src/EntityKey.ts";
import { PlanId } from "../src/Plan.id.ts";
import { Paragraph, Title } from "../src/Text.ts";
import { Phase } from "../src/Training/Phase.ts";
import { CadenceRpm, FtpFraction, Kilometers, Minutes, Seconds } from "../src/Training/Units.ts";

const UUID = "0b6f5a2e-1c3d-4e5f-8a9b-0c1d2e3f4a5b";

/** Each type, what it must accept and what it must refuse. */
const cases: ReadonlyArray<readonly [string, Schema.Top, ReadonlyArray<unknown>, ReadonlyArray<unknown>]> = [
  ["Day", Day, ["2026-11-09", "2028-02-29"], ["2026-02-30", "2027-02-29", "2026-1-09", "09-11-2026", ""]],
  ["Weekday", Weekday, [1, 7], [0, 8, 1.5]],
  ["WeekNumber", WeekNumber, [1, 104], [0, 105, 2.5]],
  ["EntityKey", EntityKey, [UUID], [UUID.toUpperCase(), "p1", ""]],
  ["PlanId", PlanId, [`i100:${UUID}`], ["i100:p1", `100:${UUID}`, UUID]],
  ["Title", Title, ["Base block"], ["", " Base", "Base ", "x".repeat(121)]],
  ["Paragraph", Paragraph, ["One hour in Z2."], ["", " ", "x".repeat(4001)]],
  ["Minutes", Minutes, [0, 45, 1440], [-1, 1441, 4.5]],
  ["Seconds", Seconds, [0, 3600, 0.5], [-1, 86_401, Number.NaN]],
  ["FtpFraction", FtpFraction, [0, 0.65, 3], [-0.1, 3.1, Number.POSITIVE_INFINITY]],
  ["Kilometers", Kilometers, [0, 160.9], [-1, 2001]],
  ["CadenceRpm", CadenceRpm, [20, 90], [19, 201, 90.5]],
  [
    "Phase",
    Phase,
    [{ focus: "base", startWeek: 1, endWeek: 4, summary: "Aerobic base" }],
    [{ focus: "base", startWeek: 5, endWeek: 4, summary: "Aerobic base" }, { focus: "rest", startWeek: 1, endWeek: 4, summary: "x" }],
  ],
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
