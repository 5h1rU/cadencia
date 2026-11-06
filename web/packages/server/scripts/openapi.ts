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
 */
import * as OpenApi from "effect/http-api/OpenApi";
import { writeFileSync } from "node:fs";
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
  // Integer bounds are Effect's safe-integer range; Swift's Int holds it.
  if (out.type === "integer") {
    delete out.minimum;
    delete out.maximum;
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

const main = async () => {
  const args = process.argv.slice(2);
  const fromIndex = args.indexOf("--from");
  const origin = fromIndex >= 0 ? args[fromIndex + 1] : undefined;
  const out = fromIndex < 0 ? args[0] : args.filter((_, i) => i !== fromIndex && i !== fromIndex + 1)[0];
  if (!out) throw new Error("Usage: node scripts/openapi.ts [--from <origin>] <out.json>");

  const source: Json = origin
    ? ((await (await fetch(new URL("/v1/openapi.json", origin))).json()) as Json)
    : (JSON.parse(JSON.stringify(OpenApi.fromApi(ClientApi))) as Json);
  const doc = plain(source) as Obj;
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
  const used = Object.fromEntries(Object.entries(schemas).filter(([name]) => reached.has(name)));

  const result = {
    ...doc,
    info: { ...(isObj(doc.info) ? doc.info : {}), title: "Cadencia", version: "1" },
    paths: referredPaths,
    components: { ...(isObj(doc.components) ? doc.components : {}), schemas: used },
  };
  writeFileSync(out, `${JSON.stringify(result, null, 2)}\n`);
};

await main();
