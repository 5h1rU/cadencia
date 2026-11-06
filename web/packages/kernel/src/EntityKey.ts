import * as Schema from "effect/Schema";

/** The shape of a lowercase UUID, for ids built from one. */
export const UUID_PATTERN = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}";

/** A random key that names one thing: a lowercase UUID. */
export const EntityKey = Schema.String.pipe(
  Schema.check(Schema.isPattern(new RegExp(`^${UUID_PATTERN}$`))),
  Schema.brand("EntityKey"),
);
export type EntityKey = typeof EntityKey.Type;
