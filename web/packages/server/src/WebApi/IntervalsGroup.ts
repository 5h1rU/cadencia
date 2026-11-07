import { ActivitySummary } from "@cadencia/athlete/ActivitySummary";
import { AthleteMeasures } from "@cadencia/athlete/AthleteMeasures";
import { HistoryRange } from "@cadencia/athlete/HistoryRange";
import { WellnessDay, WellnessDeclaration } from "@cadencia/athlete/Wellness";
import { Day } from "@cadencia/kernel/Calendar/Day";
import * as HttpApiEndpoint from "effect/http-api/HttpApiEndpoint";
import * as HttpApiGroup from "effect/http-api/HttpApiGroup";
import * as HttpApiSchema from "effect/http-api/HttpApiSchema";
import * as OpenApi from "effect/http-api/OpenApi";
import * as Schema from "effect/Schema";
import { Authentication } from "./Authentication.middleware.ts";

/** The athlete has no Intervals.icu connection any more: they must connect again. */
export class IntervalsNotConnected extends Schema.TaggedError<IntervalsNotConnected>()(
  "IntervalsNotConnected",
  {},
  { httpApiStatus: 409, description: "Connect Intervals.icu again." },
) {}

/** Intervals.icu didn't answer, or answered with an error. Trying again later may work. */
export class IntervalsUnavailable extends Schema.TaggedError<IntervalsUnavailable>()(
  "IntervalsUnavailable",
  {},
  { httpApiStatus: 502, description: "Intervals.icu did not answer. Try again." },
) {}

const errors = [IntervalsNotConnected, IntervalsUnavailable];

/**
 * Reads and declarations the web makes on Intervals.icu, the system of record,
 * as the signed-in athlete. None needs AI. Every answer is one of
 * `@cadencia/athlete`'s read models: Intervals' own names never leave the server.
 */
export const IntervalsGroup = HttpApiGroup.make("intervals")
  .add(
    HttpApiEndpoint.get("wellness", "/wellness", {
      query: HistoryRange,
      success: Schema.Array(WellnessDay),
      error: errors,
    }).annotate(OpenApi.Description, "The athlete's wellness, one entry per day of the range."),
  )
  .add(
    HttpApiEndpoint.get("activities", "/activities", {
      query: HistoryRange,
      success: Schema.Array(ActivitySummary),
      error: errors,
    }).annotate(OpenApi.Description, "The athlete's activities in the range."),
  )
  .add(
    HttpApiEndpoint.get("athlete", "/athlete", { success: AthleteMeasures, error: errors }).annotate(
      OpenApi.Description,
      "The athlete's name, weight and Ride FTP.",
    ),
  )
  .add(
    HttpApiEndpoint.put("declareWellness", "/wellness/:day", {
      params: { day: Day },
      payload: WellnessDeclaration,
      success: HttpApiSchema.NoContent,
      error: errors,
    }).annotate(OpenApi.Description, "Record how the athlete feels on a day, in their Intervals wellness."),
  )
  .middleware(Authentication)
  .prefix("/intervals")
  .annotate(OpenApi.Description, "The athlete's Intervals.icu data, in Cadencia's terms.");
