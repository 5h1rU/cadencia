import { Day } from "@cadencia/kernel/Calendar/Day";
import { describe, expect, it } from "@effect/vitest";
import * as Schema from "effect/Schema";
import * as Result from "effect/Result";
import { AsyncData } from "foldkit";
import * as Scene from "foldkit/scene";
import * as Story from "foldkit/story";
import { LoadIntervals } from "../src/command.ts";
import { init } from "../src/main.ts";
import { Message } from "../src/message.ts";
import { History, IntervalsHistory, Model } from "../src/model.ts";
import { AppRoute } from "../src/route.ts";
import { viewTransition } from "../src/transition.ts";
import { update } from "../src/update.ts";
import { view } from "../src/view.ts";
import { ana, signedIn, signedOut, today, urlOf, visit } from "./fixture.ts";

describe("the Intervals.icu history", () => {
  const range = { oldest: Day.make("2026-10-13"), newest: Day.make("2026-11-09") };
  const load = LoadIntervals({ range });
  const read = Schema.decodeUnknownSync(IntervalsHistory)({
    activities: [],
    wellness: [],
    athlete: { name: "Ana", weight: 61, ftp: 230 },
  });
  const settled = (result: Result.Result<IntervalsHistory, "signedOut" | "notConnected" | "unavailable">, at = range) =>
    Message.SettledLoadIntervals({ range: at, result });

  it("is read for the last four weeks when a section shows it, and kept on screen while it refreshes", () =>
    Story.story(
      update,
      Story.given(signedIn),
      Story.message(visit("/history")),
      Story.Command.expectExact(load),
      Story.model((model) => expect(model.history).toEqual(AsyncData.Loading())),
      Story.Command.resolve(load, settled(Result.succeed(read))),
      Story.model((model) => expect(model.history).toEqual(History.Success({ data: read }))),
      // Opening the profile reads it again, keeping what's on screen.
      Story.message(visit("/profile")),
      Story.Command.expectExact(load),
      Story.model((model) => expect(model.history).toEqual(History.Refreshing({ data: read }))),
      // A refresh that fails keeps the data and says why.
      Story.Command.resolve(load, settled(Result.fail("unavailable"))),
      Story.model((model) => expect(model.history).toEqual(History.Stale({ error: "unavailable", data: read }))),
      Story.Command.expectNone(),
    ));

  // Story answers each Command before the next Message, so what happens while a read is under way is
  // stepped through update directly.
  it("isn't read again while a read is under way", () => {
    const loading = update(signedIn, visit("/history")).model;
    const again = update(loading, visit("/profile"));
    expect(again.commands ?? []).toEqual([]);
    expect(again.model.history).toEqual(AsyncData.Loading());
  });

  it("isn't read for a signed-out visitor, nor for a section that doesn't show it", () => {
    expect(update(signedOut, visit("/profile")).commands ?? []).toEqual([]);
    expect(update(signedIn, visit("/plan")).commands ?? []).toEqual([]);
  });

  it("ignores a late answer for four weeks that are no longer shown", () => {
    const tomorrow = { oldest: Day.make("2026-10-14"), newest: Day.make("2026-11-10") };
    const loading = update(signedIn, visit("/history")).model;
    const moved = update(loading, Message.ChangedDay({ today: Day.make("2026-11-10") }));
    expect(moved.commands?.map((c) => [c.name, c.args])).toEqual([["LoadIntervals", { range: tomorrow }]]);
    const late = update(moved.model, settled(Result.succeed(read)));
    expect(late.model).toBe(moved.model);
    expect(update(late.model, settled(Result.succeed(read), tomorrow)).model.history).toEqual(History.Success({ data: read }));
  });

  it("signs out when the session is gone, and ignores an answer that arrives after", () => {
    const loading = update(signedIn, visit("/history")).model;
    const gone = update(loading, settled(Result.fail("signedOut"))).model;
    expect(gone.athleteId).toBeNull();
    expect(gone.history).toEqual(AsyncData.Idle());
    expect(update(gone, settled(Result.succeed(read))).model).toBe(gone);
  });

  it("is read again after the day's wellness is saved", () => {
    const loaded: Model = { ...signedIn, history: History.Success({ data: read }) };
    const saved = update(loaded, Message.SavedDeclaration());
    expect(saved.commands?.map((c) => [c.name, c.args])).toEqual([["LoadIntervals", { range }]]);
    expect(saved.model.history).toEqual(History.Refreshing({ data: read }));
  });

  it("grows into its cards when it first arrives, and brings new activities in when it refreshes", () => {
    const arriving = (previousModel: Model, message: Message) =>
      viewTransition({ previousModel, model: update(previousModel, message).model, message });
    const loading = update(signedIn, visit("/history")).model;
    expect(arriving(loading, settled(Result.succeed(read)))).toEqual({ types: ["reveal"] });
    const refreshing = { ...loading, history: History.Refreshing({ data: read }) };
    expect(arriving(refreshing, settled(Result.succeed(read)))).toEqual({ types: ["refresh"] });
    // A problem instead of data, a late answer that changes nothing, or a page without the history: no animation.
    expect(arriving(loading, settled(Result.fail("unavailable")))).toBe(false);
    const tomorrow = { oldest: Day.make("2026-10-14"), newest: Day.make("2026-11-10") };
    expect(arriving(loading, settled(Result.succeed(read), tomorrow))).toBe(false);
    expect(arriving({ ...loading, route: AppRoute.Plan() }, settled(Result.succeed(read)))).toBe(false);
  });

  it("keeps the activities on screen while it refreshes, and says the page is busy", () => {
    const loading = update(signedIn, visit("/history")).model;
    Scene.scene(
      { update, view },
      Scene.given(loading),
      Scene.expect(Scene.role("main")).toHaveAttr("aria-busy", "true"),
      Scene.expect(Scene.text("Actividades de las últimas cuatro semanas")).toExist(),
    );
    Scene.scene(
      { update, view },
      Scene.given({ ...loading, history: History.Refreshing({ data: read }) }),
      Scene.expect(Scene.text("Actualizando desde Intervals.icu…")).toExist(),
      Scene.expect(Scene.text("No hay actividades en Intervals.icu en estas fechas.")).toExist(),
    );
    Scene.scene(
      { update, view },
      Scene.given({ ...loading, history: History.Success({ data: read }) }),
      Scene.expect(Scene.role("main")).toHaveAttr("aria-busy", "false"),
    );
  });

  it("shows that it is reading, then why it couldn't, with a way to connect again", () => {
    const reading = update(signedIn, visit("/history")).model;
    Scene.scene({ update, view }, Scene.given(reading), Scene.expect(Scene.text("Leyendo Intervals.icu…")).toExist());
    Scene.scene(
      { update, view },
      Scene.given(update(reading, settled(Result.fail("notConnected"))).model),
      Scene.expect(Scene.text("Leyendo Intervals.icu…")).not.toExist(),
      Scene.expect(Scene.role("link", { name: "Conectar de nuevo" })).toExist(),
    );
  });

  it("is read at once when the app opens on the history page", () => {
    const opened = init({ athleteId: ana, unreachable: false, today, pageLoad: "s" }, urlOf("/history"));
    expect(opened.model.route).toEqual(AppRoute.History());
    expect(opened.commands?.map((c) => [c.name, c.args])).toEqual([["LoadIntervals", { range }]]);
  });
});
