import { AthleteId } from "@cadencia/identity/Athlete.id";
import { Calendar } from "@cadencia/planning/Plan/Calendar.external";
import { PlannedSession } from "@cadencia/planning/Plan/PlannedSession";
import { afterEach, describe, expect, it, vi } from "@effect/vitest";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as Redacted from "effect/Redacted";
import * as Schema from "effect/Schema";
import { Connections, MemoryConnections } from "../src/Connections.ts";
import { IntervalsCalendar } from "../src/Intervals/IntervalsCalendar.ts";

const anaId = AthleteId.make("i100");
const session = Schema.decodeUnknownSync(PlannedSession)({
  sessionId: "2026-11-09",
  day: "2026-11-09",
  kind: "endurance",
  title: "Easy endurance",
  targetMinutes: 60,
  purpose: "Aerobic base",
  status: "provisional",
  workout: null,
  externalId: "cadencia-i100-0b6f5a2e-1c3d-4e5f-8a9b-0c1d2e3f4a5b-2026-11-09",
});

/** Intervals answers the calendar's upsert with `body` and `status`. */
const intervalsAnswers = (body: unknown, status = 200) =>
  vi.spyOn(globalThis, "fetch").mockImplementation(async () => new Response(JSON.stringify(body), { status }));

/** Publish the session for a connected athlete, and say how it ended. */
const publish = Effect.gen(function* () {
  yield* (yield* Connections).save({ athleteId: anaId, token: Redacted.make("token"), scopes: ["CALENDAR:WRITE"] });
  const calendar = yield* Calendar;
  return yield* calendar.publishSession({ athleteId: anaId, session }).pipe(
    Effect.map(({ published }) => (published ? "published" : "not published")),
    Effect.catchTags({
      CalendarUnavailable: () => Effect.succeed("unavailable"),
      CalendarRefused: ({ problem }) => Effect.succeed(`refused: ${problem}`),
    }),
  );
}).pipe(
  Effect.provide(IntervalsCalendar.pipe(Layer.provideMerge(MemoryConnections))),
  // The in-memory connections never read the platform's RuntimeContext.
  (effect) => effect as Effect.Effect<Effect.Success<typeof effect>, Effect.Error<typeof effect>>,
);

afterEach(() => vi.restoreAllMocks());

describe("publishing to the Intervals calendar", () => {
  it.effect("counts only when Intervals names the event it wrote", () =>
    Effect.gen(function* () {
      intervalsAnswers([{ id: 42, external_id: session.externalId }]);
      expect(yield* publish).toBe("published");
    }),
  );

  it.effect("tries again when Intervals' success confirms nothing", () =>
    Effect.gen(function* () {
      intervalsAnswers([]);
      expect(yield* publish).toBe("unavailable");
      vi.restoreAllMocks();
      intervalsAnswers({});
      expect(yield* publish).toBe("unavailable");
    }),
  );

  it.effect("tells a revoked authorization from an outage", () =>
    Effect.gen(function* () {
      intervalsAnswers("unauthorized", 401);
      expect(yield* publish).toBe("refused: notConnected");
      vi.restoreAllMocks();
      intervalsAnswers("bad", 422);
      expect(yield* publish).toBe("refused: refused");
      vi.restoreAllMocks();
      intervalsAnswers("down", 503);
      expect(yield* publish).toBe("unavailable");
    }),
  );
});
