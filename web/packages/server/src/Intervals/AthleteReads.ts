import { AthleteId } from "@cadencia/kernel/Athlete.id";
import * as Effect from "effect/Effect";
import { HttpServerRequest } from "effect/http/HttpServerRequest";
import * as HttpServerResponse from "effect/http/HttpServerResponse";
import * as Option from "effect/Option";
import * as Schema from "effect/Schema";
import { Connections } from "../Connections.ts";
import { actorOf } from "../Session.ts";
import { athletePath, callIntervals } from "./IntervalsHttp.ts";

/** Only these fields leave the server: what the web shows, never Intervals' whole record. */
const pick = <K extends string>(row: unknown, keys: ReadonlyArray<K>): Partial<Record<K, unknown>> => {
  const source = (row ?? {}) as Record<string, unknown>;
  return Object.fromEntries(keys.filter((k) => source[k] !== undefined).map((k) => [k, source[k]])) as Partial<
    Record<K, unknown>
  >;
};

const WELLNESS_FIELDS = [
  "id", "ctl", "atl", "weight", "restingHR", "hrv", "sleepSecs", "sleepQuality",
  "soreness", "fatigue", "stress", "mood", "motivation", "injury", "readiness", "comments",
] as const;

const ACTIVITY_FIELDS = [
  "id", "name", "type", "start_date_local", "moving_time", "distance", "icu_training_load",
  "icu_average_watts", "icu_weighted_avg_watts", "average_heartrate", "icu_rpe", "feel",
  "paired_event_id", "compliance",
] as const;

/** What an athlete may declare from the web. Each maps to an Intervals wellness field. */
const WellnessDeclaration = Schema.Struct({
  weight: Schema.optional(Schema.Number),
  soreness: Schema.optional(Schema.Int),
  fatigue: Schema.optional(Schema.Int),
  stress: Schema.optional(Schema.Int),
  mood: Schema.optional(Schema.Int),
  motivation: Schema.optional(Schema.Int),
  sleepQuality: Schema.optional(Schema.Int),
  injury: Schema.optional(Schema.Int),
  comments: Schema.optional(Schema.String),
});

const DAY = /^\d{4}-\d{2}-\d{2}$/;

/**
 * `/api/intervals/*`: reads and declarations the web makes on Intervals.icu,
 * the system of record, as the signed-in athlete. None needs AI.
 */
export const athleteReadsRoute = Effect.gen(function* () {
  const request = yield* HttpServerRequest;
  const actor = yield* actorOf(request.headers);
  if (Option.isNone(actor) || actor.value._tag !== "Athlete") return HttpServerResponse.empty({ status: 401 });
  const athleteId: AthleteId = actor.value.athleteId;
  const connection = yield* (yield* Connections).find(athleteId);
  if (Option.isNone(connection)) return HttpServerResponse.text("Connect Intervals.icu again.", { status: 409 });
  const token = connection.value.token;
  const url = new URL(request.url, "http://localhost");
  const path = url.pathname.replace(/^\/api\/intervals/, "");
  const range = () => {
    const oldest = url.searchParams.get("oldest") ?? "";
    const newest = url.searchParams.get("newest") ?? "";
    return DAY.test(oldest) && DAY.test(newest) ? Option.some({ oldest, newest }) : Option.none();
  };
  const fail = () => HttpServerResponse.text("Intervals.icu did not answer. Try again.", { status: 502 });

  if (request.method === "GET" && path === "/wellness") {
    const r = range();
    if (Option.isNone(r)) return HttpServerResponse.text("Expected ?oldest=YYYY-MM-DD&newest=YYYY-MM-DD", { status: 400 });
    return yield* callIntervals(token, "GET", athletePath(athleteId, "/wellness"), { query: r.value }).pipe(
      Effect.flatMap((rows) => HttpServerResponse.json((Array.isArray(rows) ? rows : []).map((row) => pick(row, WELLNESS_FIELDS)))),
      Effect.catchTag("IntervalsError", () => Effect.succeed(fail())),
    );
  }
  if (request.method === "GET" && path === "/activities") {
    const r = range();
    if (Option.isNone(r)) return HttpServerResponse.text("Expected ?oldest=YYYY-MM-DD&newest=YYYY-MM-DD", { status: 400 });
    return yield* callIntervals(token, "GET", athletePath(athleteId, "/activities"), { query: r.value }).pipe(
      Effect.flatMap((rows) => HttpServerResponse.json((Array.isArray(rows) ? rows : []).map((row) => pick(row, ACTIVITY_FIELDS)))),
      Effect.catchTag("IntervalsError", () => Effect.succeed(fail())),
    );
  }
  if (request.method === "GET" && path === "/athlete") {
    return yield* callIntervals(token, "GET", athletePath(athleteId, "")).pipe(
      Effect.flatMap((athlete) => {
        const a = (athlete ?? {}) as Record<string, unknown>;
        const ride = ((a.sportSettings as Array<Record<string, unknown>>) ?? []).find((s) =>
          ((s.types as Array<string>) ?? []).includes("Ride"),
        );
        return HttpServerResponse.json({
          athleteId,
          name: a.name ?? null,
          weight: a.icu_weight ?? a.weight ?? null,
          height: a.height ?? null,
          ftp: ride?.ftp ?? null,
          measurementPreference: a.measurement_preference ?? null,
        });
      }),
      Effect.catchTag("IntervalsError", () => Effect.succeed(fail())),
    );
  }
  const wellnessDay = /^\/wellness\/(\d{4}-\d{2}-\d{2})$/.exec(path);
  if (request.method === "PUT" && wellnessDay) {
    const body = yield* request.json.pipe(Effect.flatMap(Schema.decodeUnknownEffect(WellnessDeclaration)), Effect.option);
    if (Option.isNone(body)) return HttpServerResponse.text("Unexpected wellness fields", { status: 400 });
    return yield* callIntervals(token, "PUT", athletePath(athleteId, `/wellness/${wellnessDay[1]}`), {
      body: { id: wellnessDay[1], ...body.value },
    }).pipe(
      Effect.as(HttpServerResponse.empty({ status: 204 })),
      Effect.catchTag("IntervalsError", () => Effect.succeed(fail())),
    );
  }
  if (request.method === "PUT" && path === "/ftp") {
    const body = yield* request.json.pipe(
      Effect.flatMap(Schema.decodeUnknownEffect(Schema.Struct({ ftp: Schema.Int }))),
      Effect.option,
    );
    if (Option.isNone(body) || body.value.ftp < 30 || body.value.ftp > 700) {
      return HttpServerResponse.text("Expected { ftp } between 30 and 700 W", { status: 400 });
    }
    return yield* callIntervals(token, "PUT", `/api/v1/athlete/${athleteId}/sport-settings/Ride`, {
      body: { ftp: body.value.ftp },
    }).pipe(
      Effect.as(HttpServerResponse.empty({ status: 204 })),
      Effect.catchTag("IntervalsError", () => Effect.succeed(fail())),
    );
  }
  return HttpServerResponse.text("Not Found", { status: 404 });
});
