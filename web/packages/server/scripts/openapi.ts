/**
 * Writes the OpenAPI document Cadencia iOS generates its Swift client from.
 *
 *   node scripts/openapi.ts <out.json>                 # offline, from `ClientApi`
 *   node scripts/openapi.ts --from <origin> <out.json> # from a deployment's `/v1/openapi.json`
 *
 * The served document is the source; this only makes it readable for a
 * generator that is not Effect: it keeps the calls iOS makes (every command
 * and each view's `get`), names the shared shapes, writes numbers as JSON
 * numbers, and gives each operation a short id. Nothing about the wire changes.
 *
 * It also names the domain's brands (`PlanId`, `Day`, `Minutes`, `Title`, …),
 * which Effect keeps only in TypeScript's types: each becomes a component
 * marked `x-brand`, with the pattern Effect leaves out of JSON Schema (it
 * exports only `u`-flagged patterns), and every field of that brand refers to
 * it. Swift gets one validating type per brand from that.
 */
import * as OpenApi from "effect/http-api/OpenApi";
import * as Schema from "effect/Schema";
import type * as SchemaAST from "effect/SchemaAST";
import { readdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { ClientApi } from "../src/ClientHttpApi.ts";

type Json = null | boolean | number | string | Array<Json> | { [key: string]: Json };
type Obj = { [key: string]: Json };

const isObj = (value: Json | undefined): value is Obj =>
  typeof value === "object" && value !== null && !Array.isArray(value);

/** The views iOS reads, each through its plain `get`. */
const VIEWS = ["CurrentPlan", "TodayDecision", "ConversationThread", "ConsultationView", "RiderProfileCard"];

/**
 * Effect writes a `number` as "a number, or one of the strings Infinity,
 * -Infinity, NaN". JSON has no such numbers and the domain never makes them.
 * A one-member `anyOf` is that member.
 */
const plain = (node: Json): Json => {
  if (Array.isArray(node)) return node.map(plain);
  if (!isObj(node)) return node;
  const out: Obj = {};
  for (const [k, v] of Object.entries(node)) out[k] = plain(v);
  const anyOf = out.anyOf;
  if (Array.isArray(anyOf)) {
    const finite = anyOf.filter(
      (m) => !(isObj(m) && m.type === "string" && Array.isArray(m.enum) && m.enum.includes("NaN")),
    );
    const members = finite.length < anyOf.length && finite.some((m) => isObj(m) && m.type === "number") ? finite : anyOf;
    if (members.length === 1 && isObj(members[0])) {
      const { anyOf: _, ...rest } = out;
      return { ...rest, ...members[0] };
    }
    out.anyOf = members;
  }
  // Effect bounds every integer by the safe-integer range; Swift's Int holds it. Other bounds are the domain's.
  if (out.type === "integer") {
    if (out.minimum === Number.MIN_SAFE_INTEGER) delete out.minimum;
    if (out.maximum === Number.MAX_SAFE_INTEGER) delete out.maximum;
  }
  return out;
};

const canonical = (node: Json): string =>
  JSON.stringify(node, (_, value) =>
    isObj(value) ? Object.fromEntries(Object.entries(value).sort(([a], [b]) => a.localeCompare(b))) : value,
  );

/** The object member of `T | null`. */
const nonNull = (node: Json | undefined): Json | undefined =>
  isObj(node) && Array.isArray(node.anyOf) ? node.anyOf.find((m) => isObj(m) && m.type !== "null") : node;

const at = (node: Json | undefined, ...path: Array<string>): Json | undefined =>
  path.reduce<Json | undefined>((n, key) => (key === "?" ? nonNull(n) : isObj(n) ? n[key] : undefined), node);

// MARK: Brands

interface Brand {
  readonly name: string;
  readonly ast: SchemaAST.AST;
  /** The brand's own checks; its last one is created only for it, so it identifies the brand wherever it is used. */
  readonly checks: ReadonlyArray<SchemaAST.Check<unknown>>;
  readonly schema: Obj;
}

const sourceFiles = (dir: string): Array<string> =>
  readdirSync(dir, { withFileTypes: true }).flatMap((entry) =>
    entry.isDirectory() ? sourceFiles(join(dir, entry.name)) : entry.name.endsWith(".ts") ? [join(dir, entry.name)] : [],
  );

/** The `isPattern` checks of a schema, which Effect writes to JSON Schema only when the RegExp has the `u` flag. */
const patterns = (checks: ReadonlyArray<SchemaAST.Check<unknown>>): Array<string> =>
  checks.flatMap((check): Array<string> => {
    if (check._tag === "FilterGroup") return patterns(check.checks);
    const representation = check.annotations?.representation as { id?: string; payload?: { source?: string } } | undefined;
    return representation?.id === "effect/schema/isPattern" && representation.payload?.source ? [representation.payload.source] : [];
  });

/** Every brand the domain packages export, with its JSON Schema. */
const domainBrands = async (): Promise<Array<Brand>> => {
  const brands = new Map<string, Brand>();
  for (const pkg of ["identity", "kernel", "athlete", "planning", "coach"]) {
    for (const file of sourceFiles(join(import.meta.dirname, "../..", pkg, "src"))) {
      for (const value of Object.values(await import(pathToFileURL(file).href))) {
        if (!Schema.isSchema(value) || !("schema" in value) || typeof (value as { identifier?: unknown }).identifier !== "string") continue;
        const name = (value as unknown as { identifier: string }).identifier;
        const checks = value.ast.checks ?? [];
        if (brands.has(name) || checks.length === 0) continue;
        const schema = JSON.parse(JSON.stringify(Schema.toJsonSchemaDocument(value).schema)) as Obj;
        const missing = patterns(checks).filter((p) => p !== schema.pattern);
        if (missing.length > 0 && schema.pattern === undefined) schema.pattern = missing.shift()!;
        if (missing.length > 0) schema.allOf = [...(Array.isArray(schema.allOf) ? schema.allOf : []), ...missing.map((pattern) => ({ pattern }))];
        brands.set(name, { name, ast: value.ast, checks, schema: { ...schema, "x-brand": name } });
      }
    }
  }
  return [...brands.values()];
};

/**
 * Walks a schema's AST next to the JSON Schema Effect wrote for it and replaces
 * each branded node with a reference to its brand. A node that adds checks of
 * its own (`Seconds` greater than 0) refers to the brand and keeps the keywords
 * it adds.
 */
const brandReferences = (brands: ReadonlyArray<Brand>, used: Set<string>) => {
  const brandOf = (ast: SchemaAST.AST): Brand | undefined => {
    const checks = ast.checks ?? [];
    return brands
      .filter((b) => checks.includes(b.checks[b.checks.length - 1]!))
      .sort((a, b) => b.checks.length - a.checks.length)[0];
  };
  const walk = (ast: SchemaAST.AST, json: Json): Json => {
    if (!isObj(json) || typeof json.$ref === "string") return json;
    const brand = brandOf(ast);
    if (brand) {
      used.add(brand.name);
      const ref: Obj = { $ref: `#/components/schemas/${brand.name}` };
      const added = Object.entries(json).filter(([k, v]) => k !== "type" && canonical(v) !== canonical(brand.schema[k] ?? null));
      return added.length === 0 ? ref : { allOf: [ref], ...Object.fromEntries(added) };
    }
    switch (ast._tag) {
      case "Suspend":
        return walk(ast.thunk(), json);
      case "Objects": {
        if (!isObj(json.properties)) return json;
        const properties: Obj = { ...json.properties };
        for (const p of ast.propertySignatures) {
          const key = String(p.name);
          if (key in properties) properties[key] = walk(p.type, properties[key]!);
        }
        return { ...json, properties };
      }
      case "Arrays": {
        const rest = ast.rest[0];
        return rest && json.items !== undefined ? { ...json, items: walk(rest, json.items) } : json;
      }
      case "Union": {
        if (!Array.isArray(json.anyOf)) return json;
        const types = ast.types.filter((t) => t._tag !== "Null");
        const members = json.anyOf.filter((m) => !(isObj(m) && m.type === "null"));
        if (types.length !== members.length) return json;
        let i = 0;
        return { ...json, anyOf: json.anyOf.map((m) => (isObj(m) && m.type === "null" ? m : walk(types[i++]!, m))) };
      }
      default:
        return json;
    }
  };
  return walk;
};

/** The document with every branded field referring to its brand, and the brands as components. */
const withBrands = async (doc: Obj): Promise<Obj> => {
  const brands = await domainBrands();
  const used = new Set<string>();
  const walk = brandReferences(brands, used);
  const paths: Obj = { ...(doc.paths as Obj) };
  for (const group of Object.values(ClientApi.groups)) {
    for (const endpoint of Object.values(group.endpoints)) {
      const path = endpoint.path.replace(/:(\w+)/g, "{$1}");
      const method = endpoint.method.toLowerCase();
      const item = paths[path];
      if (!isObj(item) || !isObj(item[method])) continue;
      const op: Obj = { ...item[method] };
      const payload = endpoint.payload.get("application/json")?.schemas[0];
      const body = at(op, "requestBody", "content", "application/json", "schema");
      if (payload && body) op.requestBody = { ...(op.requestBody as Obj), content: { "application/json": { schema: walk(payload.ast, body) } } };
      const success = [...endpoint.success][0];
      const response = at(op, "responses", "200");
      const responseSchema = at(response, "content", "application/json", "schema");
      if (success && isObj(response) && responseSchema) {
        op.responses = { ...(op.responses as Obj), "200": { ...response, content: { "application/json": { schema: walk(success.ast, responseSchema) } } } };
      }
      const params = endpoint.params?.ast;
      if (params && params._tag === "Objects" && Array.isArray(op.parameters)) {
        op.parameters = op.parameters.map((parameter) => {
          const signature = isObj(parameter) ? params.propertySignatures.find((p) => p.name === parameter.name) : undefined;
          return signature && isObj(parameter) && parameter.schema ? { ...parameter, schema: walk(signature.type, parameter.schema) } : parameter;
        });
      }
      paths[path] = { ...item, [method]: op };
    }
  }
  const schemas: Obj = isObj(doc.components) && isObj(doc.components.schemas) ? { ...doc.components.schemas } : {};
  for (const brand of brands) if (used.has(brand.name)) schemas[brand.name] = brand.schema;
  return { ...doc, paths, components: { ...(isObj(doc.components) ? doc.components : {}), schemas } };
};

const main = async () => {
  const args = process.argv.slice(2);
  const fromIndex = args.indexOf("--from");
  const origin = fromIndex >= 0 ? args[fromIndex + 1] : undefined;
  const out = fromIndex < 0 ? args[0] : args.filter((_, i) => i !== fromIndex && i !== fromIndex + 1)[0];
  if (!out) throw new Error("Usage: node scripts/openapi.ts [--from <origin>] <out.json>");

  const source: Json = origin
    ? ((await (await fetch(new URL("/v1/openapi.json", origin))).json()) as Json)
    : (JSON.parse(JSON.stringify(OpenApi.fromApi(ClientApi))) as Json);
  const doc = plain(await withBrands(source as Obj)) as Obj;
  const paths = doc.paths as Obj;

  // Keep what iOS calls, with short operation ids.
  const kept: Obj = {};
  for (const [path, item] of Object.entries(paths)) {
    if (!isObj(item)) continue;
    const view = /^\/v1\/(\w+)\/\{key\}$/.exec(path)?.[1];
    if (isObj(item.post)) kept[path] = { post: { ...item.post, operationId: path.slice("/v1/".length) } };
    else if (view && VIEWS.includes(view) && isObj(item.get)) kept[path] = { get: { ...item.get, operationId: `get${view}` } };
  }

  const body = (command: string) =>
    at(kept, `/v1/${command}`, "post", "requestBody", "content", "application/json", "schema", "properties", "input");
  const state = (view: string) =>
    at(kept, `/v1/${view}/{key}`, "get", "responses", "200", "content", "application/json", "schema", "?");

  // The shapes iOS translates, by name. Every structurally equal schema becomes a reference.
  const named: Array<[string, Json | undefined]> = [
    ["Receipt", at(kept, "/v1/SendMessage", "post", "responses", "200", "content", "application/json", "schema")],
    ["Workout", at(body("RecordDailyDecision"), "properties", "workout")],
    ["WorkoutStep", at(body("RecordDailyDecision"), "properties", "workout", "properties", "steps", "items")],
    ["CoachNote", at(body("RecordDailyDecision"), "properties", "note")],
    ["EvidenceSnapshot", at(body("RecordDailyDecision"), "properties", "evidence")],
    ["Readiness", at(body("RecordDailyDecision"), "properties", "evidence", "properties", "readiness")],
    ["DayConditions", at(body("RecordDailyDecision"), "properties", "evidence", "properties", "days", "items")],
    ["Intent", at(body("RecordCoachReply"), "properties", "intent", "?")],
    ["DayLimit", at(body("RecordCoachReply"), "properties", "intent", "?", "properties", "limits", "items")],
    ["PlanDraft", at(body("RecordDraft"), "properties", "draft")],
    ["PlanPhase", at(body("RecordDraft"), "properties", "draft", "properties", "phases", "items")],
    ["DraftEvent", at(body("RecordDraft"), "properties", "draft", "properties", "event", "?")],
    ["DraftSession", at(body("RecordDraft"), "properties", "draft", "properties", "sessions", "items")],
    ["RiderReport", at(body("RecordProfile"), "properties", "report")],
    ["CurrentPlanState", state("CurrentPlan")],
    ["PlannedSession", at(state("CurrentPlan"), "properties", "sessions", "items")],
    ["GoalEvent", at(state("CurrentPlan"), "properties", "event", "?")],
    ["DayRequirement", at(state("CurrentPlan"), "properties", "requirements", "items")],
    ["TodayDecisionState", state("TodayDecision")],
    ["Refusal", at(state("TodayDecision"), "properties", "refusal", "?")],
    ["ConversationThreadState", state("ConversationThread")],
    ["ThreadMessage", at(state("ConversationThread"), "properties", "messages", "items")],
    ["ConsultationViewState", state("ConsultationView")],
    ["ConsultationTurn", at(state("ConsultationView"), "properties", "turns", "items")],
    ["RiderProfileCardState", state("RiderProfileCard")],
    ["SessionKind", at(body("RecordDailyDecision"), "properties", "workout", "properties", "kind")],
    ["GoalKind", at(body("RecordDraft"), "properties", "draft", "properties", "goal")],
    ["PhaseFocus", at(body("RecordDraft"), "properties", "draft", "properties", "phases", "items", "properties", "focus")],
    ["ReadinessLevel", at(body("RecordDailyDecision"), "properties", "evidence", "properties", "readiness", "properties", "level")],
    ["InterpretedOn", at(body("RecordDailyDecision"), "properties", "interpretedOn")],
    ["SessionStatus", at(state("CurrentPlan"), "properties", "sessions", "items", "properties", "status")],
    ["RiderType", at(body("RecordProfile"), "properties", "report", "properties", "riderType")],
    ["ProfileConfidence", at(body("RecordProfile"), "properties", "report", "properties", "confidence")],
  ];
  const byShape = new Map<string, string>();
  const schemas: Obj = isObj(doc.components) && isObj(doc.components.schemas) ? { ...doc.components.schemas } : {};
  for (const [name, schema] of named) {
    if (!isObj(schema)) throw new Error(`The document no longer has the shape iOS calls ${name}.`);
    byShape.set(canonical(schema), name);
    schemas[name] = schema;
  }
  const refer = (node: Json, root: string | null): Json => {
    if (Array.isArray(node)) return node.map((n) => refer(n, null));
    if (!isObj(node)) return node;
    const name = byShape.get(canonical(node));
    if (name && name !== root) return { $ref: `#/components/schemas/${name}` };
    return Object.fromEntries(Object.entries(node).map(([k, v]) => [k, refer(v, null)]));
  };
  for (const [name, schema] of Object.entries(schemas)) schemas[name] = refer(schema, name);
  const referredPaths = refer(kept, null);

  // Only the components the kept calls reach.
  const reached = new Set<string>();
  const visit = (node: Json) => {
    if (Array.isArray(node)) return node.forEach(visit);
    if (!isObj(node)) return;
    const ref = typeof node.$ref === "string" ? node.$ref.replace("#/components/schemas/", "") : undefined;
    if (ref && !reached.has(ref)) {
      reached.add(ref);
      visit(schemas[ref] ?? null);
    }
    Object.values(node).forEach(visit);
  };
  visit(referredPaths);
  // Sorted by name, so the document doesn't change when a type moves between packages.
  const used = Object.fromEntries(
    Object.entries(schemas)
      .filter(([name]) => reached.has(name))
      .sort(([a], [b]) => a.localeCompare(b)),
  );

  const result = {
    ...doc,
    info: { ...(isObj(doc.info) ? doc.info : {}), title: "Cadencia", version: "1" },
    paths: referredPaths,
    components: { ...(isObj(doc.components) ? doc.components : {}), schemas: used },
  };
  writeFileSync(out, `${JSON.stringify(result, null, 2)}\n`);
};

await main();
