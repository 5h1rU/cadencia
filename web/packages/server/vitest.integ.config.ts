import { fileURLToPath } from "node:url";
import { defineConfig } from "vitest/config";

/**
 * The integration test on local workerd (`npx pnpm@10 test:integ` from `web/`),
 * apart from `vitest.config.ts` so `test` never deploys anything. Its root is
 * `web/`, as for `alchemy dev`: the stack names its D1 migrations from there.
 */
export default defineConfig({
  test: {
    root: fileURLToPath(new URL("../..", import.meta.url)),
    include: ["packages/server/test/integ/**/*.integ.ts"],
    testTimeout: 180_000,
    hookTimeout: 300_000,
  },
});
