import * as Domain from "@alchemy.run/domain";
import { expect, it } from "@effect/vitest";
import { Coach } from "../src/Coach.model.ts";

it("the Coach model has no definition problems", () => {
  expect(Domain.verify(Coach)).toEqual([]);
});
