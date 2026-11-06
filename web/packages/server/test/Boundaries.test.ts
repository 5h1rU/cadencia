import { describe, expect, it } from "@effect/vitest";
import { readdirSync, readFileSync } from "node:fs";
import { dirname, join, relative, resolve } from "node:path";

/**
 * What each domain package may import. Infrastructure (Cloudflare, HTTP,
 * Intervals, D1) stays in the server; the Coach reaches Planning only through
 * its `Planner` external system; the shared packages never import a context.
 */
const allowed: Record<string, ReadonlyArray<string>> = {
  identity: ["effect", "@alchemy.run/domain"],
  kernel: ["effect", "@cadencia/identity"],
  athlete: ["effect", "@cadencia/kernel"],
  planning: ["effect", "@alchemy.run/domain", "@cadencia/identity", "@cadencia/kernel", "@cadencia/athlete"],
  coach: ["effect", "@alchemy.run/domain", "@cadencia/identity", "@cadencia/kernel", "@cadencia/athlete"],
};

const packages = resolve(import.meta.dirname, "../..");

const sourceFiles = (dir: string): Array<string> =>
  readdirSync(dir, { withFileTypes: true }).flatMap((entry) =>
    entry.isDirectory() ? sourceFiles(join(dir, entry.name)) : entry.name.endsWith(".ts") ? [join(dir, entry.name)] : [],
  );

const specifiers = (source: string): Array<string> =>
  [...source.matchAll(/(?:\bfrom\s+|\bimport\s*\(?\s*)"([^"]+)"/g)].map((m) => m[1]!);

/** `@scope/name/deep/path` → `@scope/name`; `name/deep` → `name`. */
const packageOf = (specifier: string): string =>
  specifier.split("/").slice(0, specifier.startsWith("@") ? 2 : 1).join("/");

describe("domain package boundaries", () => {
  for (const [pkg, may] of Object.entries(allowed)) {
    it(`${pkg} imports only ${may.join(", ")}`, () => {
      const root = join(packages, pkg, "src");
      const breaches = sourceFiles(root).flatMap((file) =>
        specifiers(readFileSync(file, "utf8")).flatMap((specifier) => {
          const where = relative(packages, file);
          if (specifier.startsWith(".")) {
            const target = resolve(dirname(file), specifier);
            return target.startsWith(`${root}/`) ? [] : [`${where} reaches outside its package: ${specifier}`];
          }
          return may.includes(packageOf(specifier)) ? [] : [`${where} imports ${specifier}`];
        }),
      );
      expect(breaches).toEqual([]);
    });
  }
});
