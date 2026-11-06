/**
 * Writes Cadencia iOS's Swift client from the document `scripts/openapi.ts` writes:
 *
 *   node scripts/swift.ts <openapi.json> <out.swift>
 *
 * One `Codable` type per named schema and one `CadenciaAPI` method per call.
 * A key the schema requires is always sent, as `null` when Swift has no
 * value: Effect refuses a missing `NullOr` field. Each domain brand
 * (`x-brand`: `PlanId`, `Day`, `Minutes`, `Title`, …) becomes a type that
 * checks the brand's pattern, length or range when it is made or decoded, so
 * Swift cannot build a value the domain would refuse. The transport, the session
 * and the errors are hand-written in `CadenciaAPI.swift` next to the output.
 */
import { readFileSync, writeFileSync } from "node:fs";

type Json = null | boolean | number | string | Array<Json> | { [key: string]: Json };
type Obj = { [key: string]: Json };
const isObj = (value: Json | undefined): value is Obj =>
  typeof value === "object" && value !== null && !Array.isArray(value);

const [input, output] = process.argv.slice(2);
if (!input || !output) throw new Error("Usage: node scripts/swift.ts <openapi.json> <out.swift>");
const doc = JSON.parse(readFileSync(input, "utf8")) as Obj;
const components = (isObj(doc.components) && isObj(doc.components.schemas) ? doc.components.schemas : {}) as Obj;

const KEYWORDS = new Set(["default", "protocol", "class", "struct", "enum", "in", "is", "as", "func", "var", "let", "self", "Type", "operator", "repeat", "return", "where", "case", "extension", "import", "init", "internal", "private", "public", "static", "subscript", "switch", "true", "false", "nil", "throws", "try", "while", "for", "if", "else", "guard", "do", "catch"]);
const ident = (name: string) => (KEYWORDS.has(name) ? `\`${name}\`` : name);
const pascal = (name: string) => name.charAt(0).toUpperCase() + name.slice(1);
const camel = (name: string) => name.charAt(0).toLowerCase() + name.slice(1);
const refName = (ref: string) => ref.replace("#/components/schemas/", "");

/** A rejection is decoded generically from its `_tag`; it gets no type. */
const isRejection = (name: string) => name.endsWith("Encoded");

interface Resolved {
  readonly type: string;
  readonly nullable: boolean;
}

/** The Swift type of a schema; inline objects and enums become nested declarations of `nested`. */
const resolve = (schema: Json, name: string, nested: Array<string>, indent: string): Resolved | null => {
  if (!isObj(schema)) throw new Error(`Unexpected schema for ${name}`);
  if (typeof schema.$ref === "string") return { type: refName(schema.$ref), nullable: false };
  // A brand with checks of its own at this field (`Seconds` above 0): the brand's type; the domain checks the rest.
  if (Array.isArray(schema.allOf) && schema.allOf.length === 1 && isObj(schema.allOf[0]) && typeof schema.allOf[0].$ref === "string") {
    return { type: refName(schema.allOf[0].$ref), nullable: false };
  }
  if (Array.isArray(schema.anyOf)) {
    const members = schema.anyOf.filter((m) => !(isObj(m) && m.type === "null"));
    if (members.length !== 1 || members.length === schema.anyOf.length) {
      throw new Error(`${name}: only "T or null" unions are supported`);
    }
    const inner = resolve(members[0]!, name, nested, indent);
    return inner && { type: inner.type, nullable: true };
  }
  if (isObj(schema.not) && schema.not.type === "null") return { type: "EmptyObject", nullable: false };
  switch (schema.type) {
    case "null":
      return null;
    case "boolean":
      return { type: "Bool", nullable: false };
    case "integer":
      return { type: "Int", nullable: false };
    case "number":
      return { type: "Double", nullable: false };
    case "string":
      if (Array.isArray(schema.enum)) {
        const type = pascal(name);
        nested.push(enumDecl(type, schema.enum as Array<string>, indent));
        return { type, nullable: false };
      }
      return { type: "String", nullable: false };
    case "array": {
      const item = resolve(schema.items ?? null, name.endsWith("s") ? name.slice(0, -1) : `${name}Item`, nested, indent);
      if (!item) throw new Error(`${name}: array of null`);
      return { type: `[${item.type}${item.nullable ? "?" : ""}]`, nullable: false };
    }
    case "object": {
      const type = pascal(name);
      nested.push(structDecl(type, schema, indent));
      return { type, nullable: false };
    }
  }
  throw new Error(`${name}: unsupported schema ${JSON.stringify(schema)}`);
};

const enumDecl = (type: string, values: Array<string>, indent: string): string =>
  [
    `${indent}public enum ${type}: String, Codable, Equatable, Sendable, CaseIterable {`,
    ...values.map((v) => `${indent}    case ${ident(v)}${/^[A-Za-z_][A-Za-z0-9_]*$/.test(v) ? "" : ` = ${JSON.stringify(v)}`}`),
    `${indent}}`,
  ].join("\n");

const structDecl = (type: string, schema: Obj, indent: string): string => {
  const required = new Set(Array.isArray(schema.required) ? (schema.required as Array<string>) : []);
  const nested: Array<string> = [];
  const fields: Array<{ name: string; key: string; type: string; optional: boolean; required: boolean }> = [];
  for (const [key, property] of Object.entries(isObj(schema.properties) ? schema.properties : {})) {
    const resolved = resolve(property, key, nested, `${indent}    `);
    if (!resolved) continue; // a field that is always null carries nothing
    const optional = resolved.nullable || !required.has(key);
    fields.push({ name: ident(key), key, type: resolved.type, optional, required: required.has(key) });
  }
  const lines = [`${indent}public struct ${type}: Codable, Equatable, Sendable {`];
  for (const decl of nested) lines.push(decl, "");
  for (const f of fields) lines.push(`${indent}    public var ${f.name}: ${f.type}${f.optional ? "?" : ""}`);
  const params = fields.map((f) => `${f.key}: ${f.type}${f.optional ? "? = nil" : ""}`).join(", ");
  lines.push("", `${indent}    public init(${params}) {`);
  for (const f of fields) lines.push(`${indent}        self.${f.key} = ${f.key}`);
  lines.push(`${indent}    }`);
  if (fields.length > 0) {
    lines.push("", `${indent}    private enum CodingKeys: String, CodingKey {`);
    lines.push(`${indent}        case ${fields.map((f) => f.name).join(", ")}`);
    lines.push(`${indent}    }`);
  }
  lines.push("", `${indent}    public func encode(to encoder: Encoder) throws {`);
  if (fields.length > 0) {
    lines.push(`${indent}        var container = encoder.container(keyedBy: CodingKeys.self)`);
    for (const f of fields) {
      // A required key is always written: `null` when there is no value.
      const method = f.required ? "encode" : "encodeIfPresent";
      lines.push(`${indent}        try container.${method}(${f.key}, forKey: .${f.name})`);
    }
  } else {
    lines.push(`${indent}        _ = encoder.container(keyedBy: CodingKeys.self)`);
  }
  lines.push(`${indent}    }`, `${indent}}`);
  return lines.join("\n");
};

/** A Swift raw string literal; the brands' patterns have no `"#`. */
const rawString = (text: string) => {
  if (text.includes('"#')) throw new Error(`Cannot quote ${text}`);
  return `#"${text}"#`;
};

/** A domain brand: a `RawRepresentable` that only holds values the domain accepts. */
const brandDecl = (name: string, schema: Obj, indent: string): string => {
  const raw = schema.type === "string" ? "String" : schema.type === "integer" ? "Int" : schema.type === "number" ? "Double" : null;
  if (!raw) throw new Error(`${name}: a brand of ${String(schema.type)}`);
  const conditions: Array<string> = [];
  const described: Array<string> = [];
  if (raw === "Double") conditions.push("value.isFinite");
  if (typeof schema.minimum === "number") { conditions.push(`value >= ${schema.minimum}`); described.push(`at least ${schema.minimum}`); }
  if (typeof schema.exclusiveMinimum === "number") { conditions.push(`value > ${schema.exclusiveMinimum}`); described.push(`above ${schema.exclusiveMinimum}`); }
  if (typeof schema.maximum === "number") { conditions.push(`value <= ${schema.maximum}`); described.push(`at most ${schema.maximum}`); }
  if (typeof schema.exclusiveMaximum === "number") { conditions.push(`value < ${schema.exclusiveMaximum}`); described.push(`below ${schema.exclusiveMaximum}`); }
  // JavaScript counts a string's length in UTF-16 code units.
  if (typeof schema.minLength === "number") { conditions.push(`value.utf16.count >= ${schema.minLength}`); described.push(`${schema.minLength}+ characters`); }
  if (typeof schema.maxLength === "number") { conditions.push(`value.utf16.count <= ${schema.maxLength}`); described.push(`up to ${schema.maxLength} characters`); }
  const patterns = [
    ...(typeof schema.pattern === "string" ? [schema.pattern] : []),
    ...(Array.isArray(schema.allOf) ? schema.allOf.flatMap((m) => (isObj(m) && typeof m.pattern === "string" ? [m.pattern] : [])) : []),
  ];
  for (const pattern of patterns) {
    conditions.push(`CadenciaAPI.matches(value, ${rawString(pattern)})`);
    described.push(`\`${pattern}\``);
  }
  const numeric = raw !== "String";
  const lines = [
    `${indent}/// The domain's \`${name}\`${described.length > 0 ? `: ${described.join(", ")}` : ""}.`,
    `${indent}public struct ${name}: CadenciaAPI.Branded${numeric ? ", Comparable" : ""}${typeof schema.maxLength === "number" ? ", CadenciaAPI.BoundedText" : ""} {`,
    `${indent}    public let rawValue: ${raw}`,
  ];
  if (typeof schema.maxLength === "number") lines.push(`${indent}    public static let maxLength = ${schema.maxLength}`);
  lines.push(
    "",
    `${indent}    public init?(rawValue: ${raw}) {`,
    `${indent}        guard Self.accepts(rawValue) else { return nil }`,
    `${indent}        self.rawValue = rawValue`,
    `${indent}    }`,
    "",
    `${indent}    public static func accepts(_ value: ${raw}) -> Bool {`,
    `${indent}        ${conditions.length > 0 ? conditions.join(" && ") : "true"}`,
    `${indent}    }`,
  );
  if (numeric) lines.push("", `${indent}    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }`);
  lines.push(`${indent}}`);
  return lines.join("\n");
};

const out: Array<string> = [
  "// Generated by web/packages/server/scripts/swift.ts from CadenciaCore/OpenAPI/openapi.json.",
  "// Do not edit. Regenerate with `npx pnpm@10 --filter @cadencia/server ios-client` from web/.",
  "",
  "import Foundation",
  "",
  "// The wire types, nested so they never clash with CadenciaCore's own `Workout`, `SessionKind`, ….",
  "extension CadenciaAPI {",
];

for (const [name, schema] of Object.entries(components)) {
  if (isRejection(name) || !isObj(schema)) continue;
  if (typeof schema["x-brand"] === "string") out.push(brandDecl(name, schema, "    "), "");
  else if (schema.type === "string" && Array.isArray(schema.enum)) out.push(enumDecl(name, schema.enum as Array<string>, "    "), "");
  else if (schema.type === "object") out.push(structDecl(name, schema, "    "), "");
  else throw new Error(`${name}: unsupported component`);
}

const methods: Array<string> = [];
const content = (response: Json | undefined) =>
  isObj(response) && isObj(response.content) && isObj(response.content["application/json"])
    ? response.content["application/json"].schema
    : undefined;
const rejections = (responses: Obj) =>
  Object.entries(responses)
    .filter(([status]) => status !== "200")
    .map(([status, r]) => `${isObj(r) ? String(r.description) : "?"} (${status})`)
    .join(", ");

for (const [path, item] of Object.entries(isObj(doc.paths) ? doc.paths : {})) {
  if (!isObj(item)) continue;
  if (isObj(item.post)) {
    const op = item.post;
    const name = String(op.operationId);
    const body = content(isObj(op.requestBody) ? op.requestBody : undefined);
    const inputSchema = isObj(body) && isObj(body.properties) ? body.properties.input : undefined;
    const target = resolve(isObj(body) && isObj(body.properties) ? (body.properties.target ?? null) : null, `${name}Target`, [], "    ");
    if (!target || target.nullable) throw new Error(`${name}: expected a target`);
    const targetValue = target.type === "String" ? "target" : "target.rawValue";
    const nested: Array<string> = [];
    const resolved = resolve(inputSchema ?? null, `${name}Input`, nested, "    ");
    out.push(...nested.flatMap((n) => [n, ""]));
    const success = content(isObj(op.responses) ? op.responses["200"] : undefined);
    if (!isObj(success) || success.$ref !== "#/components/schemas/Receipt") throw new Error(`${name}: expected a Receipt`);
    const empty = !resolved || resolved.type === "EmptyObject";
    methods.push(
      `    /// \`POST ${path}\`. Rejections: ${rejections(isObj(op.responses) ? op.responses : {})}.`,
      empty
        ? `    public func ${camel(name)}(_ target: ${target.type}, commandId: String? = nil) async throws -> Receipt {\n        try await command(${JSON.stringify(name)}, target: ${targetValue}, input: EmptyObject(), commandId: commandId)\n    }`
        : `    public func ${camel(name)}(_ target: ${target.type}, _ input: ${resolved.type}, commandId: String? = nil) async throws -> Receipt {\n        try await command(${JSON.stringify(name)}, target: ${targetValue}, input: input, commandId: commandId)\n    }`,
      "",
    );
  } else if (isObj(item.get)) {
    const op = item.get;
    const view = /^\/v1\/(\w+)\/\{key\}$/.exec(path)?.[1];
    if (!view) throw new Error(`${path}: not a view read`);
    const success = content(isObj(op.responses) ? op.responses["200"] : undefined);
    const resolved = resolve(success ?? null, `${view}State`, [], "");
    if (!resolved || !resolved.nullable) throw new Error(`${view}: expected "state or null"`);
    const keyParameter = Array.isArray(op.parameters) ? op.parameters.find((p) => isObj(p) && p.name === "key") : undefined;
    const key = resolve(isObj(keyParameter) ? (keyParameter.schema ?? null) : null, `${view}Key`, [], "");
    if (!key || key.nullable) throw new Error(`${view}: expected a key`);
    methods.push(
      `    /// \`GET ${path}\`: nil while the key has no data. With \`after\`, waits until the view includes that write.`,
      `    /// Rejections: ${rejections(isObj(op.responses) ? op.responses : {})}.`,
      `    public func ${String(op.operationId)}(_ key: ${key.type}, after receipt: Receipt? = nil) async throws -> ${resolved.type}? {\n        try await read(${JSON.stringify(view)}, key: ${key.type === "String" ? "key" : "key.rawValue"}, after: receipt)\n    }`,
      "",
    );
  }
}

if (out[out.length - 1] === "") out.pop(); // the blank line after the last type
out.push("}", "", "extension CadenciaAPI {", ...methods.slice(0, -1), "}", "");
writeFileSync(output, out.join("\n"));
