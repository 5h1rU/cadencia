import { describe, expect, it } from "@effect/vitest";
import * as Duration from "effect/Duration";
import { localDayOf, untilNextMidnight } from "../src/subscription.ts";

describe("the local day", () => {
  it("is the athlete's calendar day, and the next one starts just after local midnight", () => {
    const evening = new Date(2026, 10, 9, 23, 59, 0);
    expect(localDayOf(evening)).toBe("2026-11-09");
    expect(Duration.toMillis(untilNextMidnight(evening))).toBe(61_000);
    expect(localDayOf(new Date(evening.getTime() + Duration.toMillis(untilNextMidnight(evening))))).toBe("2026-11-10");
  });
});
