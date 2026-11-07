import { Day } from "@cadencia/kernel/Calendar/Day";
import { describe, expect, it } from "@effect/vitest";
import * as Option from "effect/Option";
import * as Schema from "effect/Schema";
import { ConversationId, monthOf, YearMonth } from "../src/Conversation/Conversation.id.ts";
import { MessageId } from "../src/Conversation/Message.id.ts";
import { MessageText } from "../src/Conversation/MessageText.ts";
import { Count } from "../src/Count.ts";
import { Attempt } from "../src/DailyDecision/Attempt.ts";
import { DailyDecisionId } from "../src/DailyDecision/DailyDecision.id.ts";
import { Headline } from "../src/Headline.ts";
import { ModelName } from "../src/Provenance.ts";

const UUID = "0b6f5a2e-1c3d-4e5f-8a9b-0c1d2e3f4a5b";

/** Each type, what it must accept and what it must refuse. */
const cases: ReadonlyArray<readonly [string, Schema.Top, ReadonlyArray<unknown>, ReadonlyArray<unknown>]> = [
  ["YearMonth", YearMonth, ["2026-11"], ["2026-13", "2026-1", "2026-11-01"]],
  ["ConversationId", ConversationId, ["i100:2026-11"], ["i100:2026-13", "100:2026-11", "i100"]],
  ["MessageId", MessageId, [UUID], ["m1", UUID.toUpperCase()]],
  ["Headline", Headline, ["Easy endurance"], ["", "x".repeat(201)]],
  ["MessageText", MessageText, ["Thursday I only have 45 minutes"], ["", "x".repeat(8001)]],
  ["ModelName", ModelName, ["gpt-5.5", "claude-opus-5-5"], ["", "gpt 5", "-gpt"]],
  ["Count", Count, [0, 12], [-1, 1.5]],
  ["Attempt", Attempt, [1, 2], [0, -1]],
  ["DailyDecisionId", DailyDecisionId, ["i100:2026-11-09", "i100:2028-02-29"], ["i100:2026-02-31", "i100:2027-02-29", "i100:2026-11-9"]],
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

describe("conversations", () => {
  it("keep one month each", () => {
    expect(monthOf(Day.make("2026-11-09"))).toBe("2026-11");
  });
});
