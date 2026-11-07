import * as Schema from "effect/Schema";

/** The AI model that produced an interpretation, such as `gpt-5.5`. */
export const ModelName = Schema.String.pipe(
  Schema.check(Schema.isPattern(/^[A-Za-z0-9][A-Za-z0-9._:/-]{0,99}$/)),
  Schema.brand("ModelName"),
);
export type ModelName = typeof ModelName.Type;

/** Which device or service ran the AI that produced an interpretation. */
export const InterpretedOn = Schema.Literals(["ios"]);
export type InterpretedOn = typeof InterpretedOn.Type;

/** Where an interpretation came from: the model and the place it ran. */
export const Provenance = Schema.Struct({ model: ModelName, interpretedOn: InterpretedOn });
export type Provenance = typeof Provenance.Type;
