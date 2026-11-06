import type { AthleteId } from "@cadencia/kernel/Athlete.id";
import * as Cloudflare from "@alchemy.run/cloudflare";
import * as Alchemy from "alchemy";
import type { RuntimeContext } from "alchemy/RuntimeContext";
import * as Context from "effect/Context";
import * as Effect from "effect/Effect";
import * as Base64Url from "effect/encoding/Base64Url";
import * as Layer from "effect/Layer";
import * as Option from "effect/Option";
import * as Redacted from "effect/Redacted";
import * as Result from "effect/Result";

/** An athlete's Intervals.icu connection: the OAuth token Cadencia acts with. */
export interface Connection {
  readonly athleteId: AthleteId;
  readonly token: Redacted.Redacted<string>;
  readonly scopes: ReadonlyArray<string>;
}

/**
 * Where each athlete's Intervals token lives. Outside the domain's event
 * history on purpose: a token must be deletable for good.
 */
export class Connections extends Context.Service<
  Connections,
  {
    readonly save: (connection: Connection) => Effect.Effect<void, never, RuntimeContext>;
    readonly find: (athleteId: AthleteId) => Effect.Effect<Option.Option<Connection>, never, RuntimeContext>;
    readonly athletes: Effect.Effect<ReadonlyArray<AthleteId>, never, RuntimeContext>;
    readonly remove: (athleteId: AthleteId) => Effect.Effect<void, never, RuntimeContext>;
  }
>()("Cadencia/Connections") {}

/** In memory, for tests and local runs. */
export const MemoryConnections = Layer.sync(Connections, () => {
  const rows = new Map<string, Connection>();
  return {
    save: (connection) => Effect.sync(() => void rows.set(connection.athleteId, connection)),
    find: (athleteId) => Effect.sync(() => Option.fromNullishOr(rows.get(athleteId))),
    athletes: Effect.sync(() => [...rows.values()].map((c) => c.athleteId)),
    remove: (athleteId) => Effect.sync(() => void rows.delete(athleteId)),
  };
});

/** The D1 database that holds the connections, in the EU like the rest of the athlete's data. */
export const ConnectionsDatabase = Cloudflare.D1.Database("ConnectionsDatabase", {
  migrations: "packages/server/migrations/connections",
  jurisdiction: "eu",
});

/** Tokens are encrypted with AES-GCM under a random key kept in the stage's state. */
const aesKey = (secret: Redacted.Redacted<string>) =>
  Effect.promise(async () => {
    const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(Redacted.value(secret)));
    return crypto.subtle.importKey("raw", digest, "AES-GCM", false, ["encrypt", "decrypt"]);
  });

const encrypt = (key: CryptoKey, plain: string) =>
  Effect.promise(async () => {
    const iv = crypto.getRandomValues(new Uint8Array(12));
    const sealed = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv }, key, new TextEncoder().encode(plain)));
    const joined = new Uint8Array(iv.length + sealed.length);
    joined.set(iv);
    joined.set(sealed, iv.length);
    return Base64Url.encode(joined);
  });

const decrypt = (key: CryptoKey, encoded: string) =>
  Effect.gen(function* () {
    const bytes = Base64Url.decode(encoded);
    if (Result.isFailure(bytes)) return yield* Effect.die(new Error("Unreadable token ciphertext"));
    const joined = bytes.success;
    const plain = yield* Effect.promise(() =>
      crypto.subtle.decrypt({ name: "AES-GCM", iv: joined.slice(0, 12) }, key, joined.slice(12)),
    );
    return new TextDecoder().decode(plain);
  });

interface Row {
  readonly athlete_id: string;
  readonly token_ciphertext: string;
  readonly scopes: string;
}

/** Connections in D1, encrypted. */
export const D1Connections = Layer.effect(
  Connections,
  Effect.gen(function* () {
    const db = yield* Cloudflare.D1.QueryDatabase(yield* ConnectionsDatabase);
    const secret = yield* (yield* Alchemy.Random("ConnectionsKey")).text;
    const cipherKey = Effect.flatMap(secret, aesKey);
    const toConnection = (row: Row) =>
      Effect.flatMap(cipherKey, (key) => decrypt(key, row.token_ciphertext)).pipe(
        Effect.map(
          (token): Connection => ({
            athleteId: row.athlete_id as AthleteId,
            token: Redacted.make(token),
            scopes: row.scopes.split(",").filter(Boolean),
          }),
        ),
      );
    return {
      save: (connection) =>
        Effect.gen(function* () {
          const ciphertext = yield* encrypt(yield* cipherKey, Redacted.value(connection.token));
          yield* db
            .prepare(
              "INSERT INTO intervals_connections (athlete_id, token_ciphertext, scopes, connected_at) VALUES (?, ?, ?, ?) " +
                "ON CONFLICT (athlete_id) DO UPDATE SET token_ciphertext = excluded.token_ciphertext, scopes = excluded.scopes, connected_at = excluded.connected_at",
            )
            .bind(connection.athleteId, ciphertext, connection.scopes.join(","), new Date().toISOString())
            .run();
        }).pipe(Effect.orDie),
      find: (athleteId) =>
        db
          .prepare("SELECT athlete_id, token_ciphertext, scopes FROM intervals_connections WHERE athlete_id = ?")
          .bind(athleteId)
          .first<Row>()
          .pipe(
            Effect.orDie,
            Effect.flatMap((row) => (row ? Effect.map(toConnection(row), Option.some) : Effect.succeed(Option.none()))),
          ),
      athletes: db
        .prepare("SELECT athlete_id FROM intervals_connections")
        .all<{ athlete_id: string }>()
        .pipe(
          Effect.orDie,
          Effect.map((result) => result.results.map((r) => r.athlete_id as AthleteId)),
        ),
      remove: (athleteId) =>
        db.prepare("DELETE FROM intervals_connections WHERE athlete_id = ?").bind(athleteId).run().pipe(Effect.orDie, Effect.asVoid),
    };
  }),
);
