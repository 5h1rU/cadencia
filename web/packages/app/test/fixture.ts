import { AthleteId } from "@cadencia/identity/Athlete.id";
import { Day } from "@cadencia/kernel/Calendar/Day";
import { CurrentPlanState } from "@cadencia/planning/Plan/CurrentPlan.view";
import * as DateTime from "effect/DateTime";
import * as Option from "effect/Option";
import * as Schema from "effect/Schema";
import { FieldValidation, Url } from "foldkit";
import { init } from "../src/main.ts";
import { Message } from "../src/message.ts";

export const ana = AthleteId.make("i100");

/** The reasons a field fails its rules, if it does. */
export const errorsOf = (field: FieldValidation.Field<string>) =>
  field._tag === "Invalid" ? Option.some(field.errors) : Option.none();
export const today = Day.make("2026-11-09");
/** A URL on the web's own origin. */
export const urlOf = (path: string) => Option.getOrThrow(Url.fromString(`http://localhost${path}`));
const home = urlOf("/");

export const signedIn = init({ athleteId: ana, unreachable: false, today, pageLoad: "s" }, home).model;
export const signedOut = init({ athleteId: null, unreachable: false, today, pageLoad: "s" }, home).model;

/** The athlete moving to one of the web's pages. */
export const visit = (path: string) => Message.ChangedUrl({ url: urlOf(path) });

export const plan = Schema.decodeUnknownSync(CurrentPlanState)({
  planId: "i100:0b6f5a2e-1c3d-4e5f-8a9b-0c1d2e3f4a5b",
  status: "active",
  title: "Base de invierno",
  goal: "endurance",
  objective: "Llegar a marzo con 3 horas cómodas.",
  startDay: "2026-11-02",
  endDay: "2026-12-27",
  phases: [],
  longRideWeekday: null,
  event: null,
  sessions: [
    ["2026-11-10", "published"],
    ["2026-11-11", "changedInIntervals"],
    ["2026-11-12", "skipped"],
    ["2026-11-13", "provisional"],
  ].map(([day, status]) => ({
    sessionId: day,
    day,
    kind: "endurance",
    title: "Resistencia",
    targetMinutes: 60,
    purpose: "Base aeróbica.",
    status,
    workout: null,
    externalId: `cadencia-i100-0b6f5a2e-1c3d-4e5f-8a9b-0c1d2e3f4a5b-${day}`,
  })),
  requirements: [],
  calendarProblems: [{ sessionId: "2026-11-13", problem: "notConnected" }],
  createdAt: DateTime.makeUnsafe("2026-11-01T08:00:00Z"),
});

/** Dependencies a subscription can restart on: they must decode with its own schema. */
export const wellFormed = (schema: Schema.Top, value: unknown) =>
  Schema.decodeUnknownSync(schema as unknown as Schema.Codec<unknown, unknown, never>)(value);
