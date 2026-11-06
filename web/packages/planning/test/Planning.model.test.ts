import * as Domain from "@alchemy.run/domain";
import { expect, it } from "@effect/vitest";
import { Planning } from "../src/Planning.model.ts";

it("the Planning model has no definition problems", () => {
  expect(Domain.verify(Planning)).toEqual([]);
});
