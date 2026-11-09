import { describe, expect, it } from "@effect/vitest";
import { intervalsProblemOf } from "../src/domain/intervalsProblem.ts";

describe("the server's Intervals statuses, as the athlete reads them", () => {
  it("are signed out, not connected, or Intervals not answering", () => {
    expect(intervalsProblemOf(401)).toBe("signedOut");
    expect(intervalsProblemOf(409)).toBe("notConnected");
    expect(intervalsProblemOf(502)).toBe("unavailable");
    expect(intervalsProblemOf(500)).toBe("unavailable");
  });
});
