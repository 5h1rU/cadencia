import { IntervalsActivityId } from "@cadencia/athlete/Activity.id";
import { ActivitySummary } from "@cadencia/athlete/ActivitySummary";
import { AthleteMeasures } from "@cadencia/athlete/AthleteMeasures";
import type { HistoryRange } from "@cadencia/athlete/HistoryRange";
import { Bpm, FtpWatts, HrvMs, Kilograms, Rpe, TrainingLoad, Watts, WellnessScale } from "@cadencia/athlete/Measures";
import { WellnessDay, WellnessDeclaration } from "@cadencia/athlete/Wellness";
import type { AthleteId } from "@cadencia/identity/Athlete.id";
import { Day } from "@cadencia/kernel/Calendar/Day";
import { Paragraph, Title } from "@cadencia/kernel/Text";
import { Kilometers, Seconds } from "@cadencia/kernel/Training/Units";
import { IntervalsNotConnected, IntervalsUnavailable } from "../WebApi/IntervalsGroup.ts";
import * as Effect from "effect/Effect";
import * as Option from "effect/Option";
import type * as Redacted from "effect/Redacted";
import * as Schema from "effect/Schema";
import { athletePath, callIntervals, type IntervalsError, kindOf } from "./IntervalsHttp.ts";

// The edge between Intervals.icu and the web: each row Intervals returns is
// decoded here into Cadencia's read models (`@cadencia/athlete`), and only
// those leave the server. Intervals' own names and values never reach the app.
// The web reaches these through `WebApi`'s `intervals` group.

type Row = Readonly<Record<string, unknown>>;

const rowOf = (value: unknown): Row =>
  typeof value === "object" && value !== null && !Array.isArray(value) ? (value as Row) : {};

/** The value when `schema` accepts it, else null: one field Cadencia can't use never loses the row. */
const orNull = <S extends Schema.ConstraintDecoder<unknown>>(schema: S, value: unknown): S["Type"] | null =>
  Option.getOrNull(Schema.decodeUnknownOption(schema)(value));

/** Text any app, or the athlete, wrote: trimmed first, as Cadencia's text never has outer spaces. */
const trimmed = (value: unknown) => (typeof value === "string" ? value.trim() : value);

/** An Intervals activity, or none when it has no id Cadencia can name it by. */
export const activityFromIntervals = (value: unknown): Option.Option<ActivitySummary> => {
  const row = rowOf(value);
  return Option.map(Schema.decodeUnknownOption(IntervalsActivityId)(row.id), (activityId) => ({
    activityId,
    day: orNull(Day, typeof row.start_date_local === "string" ? row.start_date_local.slice(0, 10) : null),
    name: orNull(Title, trimmed(row.name)),
    movingTime: orNull(Seconds, row.moving_time),
    // Intervals measures distance in metres.
    distance: orNull(Kilometers, typeof row.distance === "number" ? row.distance / 1000 : null),
    trainingLoad: orNull(TrainingLoad, row.icu_training_load),
    averagePower: orNull(Watts, row.icu_average_watts),
    normalizedPower: orNull(Watts, row.icu_weighted_avg_watts),
    averageHeartRate: orNull(Bpm, row.average_heartrate),
    rpe: orNull(Rpe, row.icu_rpe),
  }));
};

/** A day of Intervals wellness, or none when its id is not a day. */
export const wellnessFromIntervals = (value: unknown): Option.Option<WellnessDay> => {
  const row = rowOf(value);
  return Option.map(Schema.decodeUnknownOption(Day)(row.id), (day) => ({
    day,
    fitness: orNull(TrainingLoad, row.ctl),
    acuteLoad: orNull(TrainingLoad, row.atl),
    weight: orNull(Kilograms, row.weight),
    restingHeartRate: orNull(Bpm, row.restingHR),
    hrv: orNull(HrvMs, row.hrv),
    sleep: orNull(Seconds, row.sleepSecs),
    sleepQuality: orNull(WellnessScale, row.sleepQuality),
    soreness: orNull(WellnessScale, row.soreness),
    fatigue: orNull(WellnessScale, row.fatigue),
    stress: orNull(WellnessScale, row.stress),
    mood: orNull(WellnessScale, row.mood),
    motivation: orNull(WellnessScale, row.motivation),
    injury: orNull(WellnessScale, row.injury),
    comments: orNull(Paragraph, trimmed(row.comments)),
  }));
};

/** The athlete's Intervals record: their name, weight and Ride FTP. */
export const measuresFromIntervals = (value: unknown): AthleteMeasures => {
  const athlete = rowOf(value);
  const settings = Array.isArray(athlete.sportSettings) ? athlete.sportSettings.map(rowOf) : [];
  const ride = settings.find((s) => Array.isArray(s.types) && s.types.includes("Ride"));
  return {
    name: orNull(Title, trimmed(athlete.name)),
    weight: orNull(Kilograms, athlete.icu_weight ?? athlete.weight),
    ftp: orNull(FtpWatts, ride?.ftp),
  };
};

/** Every row of a list Intervals returned that decodes; anything else is left out. */
export const rowsFromIntervals = <A>(rows: unknown, decode: (row: unknown) => Option.Option<A>): ReadonlyArray<A> =>
  Array.isArray(rows) ? rows.flatMap((row) => Option.toArray(decode(row))) : [];

/** A declaration as Intervals' wellness record: Cadencia's names are Intervals' here, and the day is its id. */
export const wellnessForIntervals = (day: Day, declaration: WellnessDeclaration) => ({
  id: day,
  ...Schema.encodeSync(WellnessDeclaration)(declaration),
});

/**
 * Intervals' error as the web's: a revoked authorization asks the athlete to
 * connect again, anything else is Intervals not answering as it should.
 */
const unavailable = Effect.mapError((error: IntervalsError) =>
  kindOf(error) === "notConnected" ? new IntervalsNotConnected() : new IntervalsUnavailable(),
);

/** The athlete's wellness in a range, from Intervals. */
export const readWellness = (token: Redacted.Redacted<string>, athleteId: AthleteId, range: HistoryRange) =>
  callIntervals(token, "GET", athletePath(athleteId, "/wellness"), { query: range }).pipe(
    Effect.map((rows) => rowsFromIntervals(rows, wellnessFromIntervals)),
    unavailable,
  );

/** The athlete's activities in a range, from Intervals. */
export const readActivities = (token: Redacted.Redacted<string>, athleteId: AthleteId, range: HistoryRange) =>
  callIntervals(token, "GET", athletePath(athleteId, "/activities"), { query: range }).pipe(
    Effect.map((rows) => rowsFromIntervals(rows, activityFromIntervals)),
    unavailable,
  );

/** The athlete's name, weight and Ride FTP, from Intervals. */
export const readMeasures = (token: Redacted.Redacted<string>, athleteId: AthleteId) =>
  callIntervals(token, "GET", athletePath(athleteId, "")).pipe(Effect.map(measuresFromIntervals), unavailable);

/** Record a wellness declaration in Intervals, where it belongs. */
export const declareWellness = (
  token: Redacted.Redacted<string>,
  athleteId: AthleteId,
  day: Day,
  declaration: WellnessDeclaration,
) =>
  callIntervals(token, "PUT", athletePath(athleteId, `/wellness/${day}`), {
    body: wellnessForIntervals(day, declaration),
  }).pipe(Effect.asVoid, unavailable);
