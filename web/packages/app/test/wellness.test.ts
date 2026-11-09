import { Day } from "@cadencia/kernel/Calendar/Day";
import { describe, expect, it } from "@effect/vitest";
import * as Option from "effect/Option";
import * as Schema from "effect/Schema";
import * as Result from "effect/Result";
import { AsyncData, FieldValidation } from "foldkit";
import * as Scene from "foldkit/scene";
import { declarationOf } from "../src/domain/form.ts";
import { Message } from "../src/message.ts";
import { History, IntervalsHistory, Model } from "../src/model.ts";
import { AppRoute } from "../src/route.ts";
import { update } from "../src/update.ts";
import { view } from "../src/view.ts";
import { errorsOf, signedIn, today } from "./fixture.ts";

describe("the wellness form", () => {
  const onProfile: Model = { ...signedIn, route: AppRoute.Profile() };
  const fill = (fields: Partial<Record<"mood" | "motivation" | "soreness" | "fatigue" | "weight" | "comments", string>>) =>
    Object.entries(fields).reduce(
      (m, [field, value]) =>
        update(m, Message.UpdatedDeclaration({ field: field as "mood", value: value ?? "" })).model,
      onProfile,
    );

  it("sends only what the athlete filled in, in Intervals' units", () => {
    const saved = update(fill({ mood: "3", weight: "74.1", comments: " Legs heavy " }), Message.SubmittedDeclaration());
    expect(saved.commands?.map((c) => [c.name, c.args])).toEqual([
      ["SaveDeclaration", { day: today, declaration: { mood: 3, weight: 74.1, comments: "Legs heavy" } }],
    ]);
    expect(Option.getOrNull(declarationOf(fill({ mood: "3" }).declaration))).toEqual({ mood: 3 });
  });

  it("refuses values outside Intervals' scales, saying so under the field", () => {
    const heavy = fill({ weight: "7" });
    expect(Option.getOrNull(errorsOf(heavy.declaration.weight))).toEqual(["Entre 20 y 350 kg."]);
    expect(update(heavy, Message.SubmittedDeclaration()).commands ?? []).toEqual([]);
    expect(Option.isNone(declarationOf(fill({ mood: "5" }).declaration))).toBe(true);
    expect(Option.isNone(declarationOf(fill({ fatigue: "two" }).declaration))).toBe(true);
  });

  it("can't be edited while it saves, so saving clears only what was sent", () =>
    Scene.scene(
      { update, view },
      Scene.given(update(fill({ comments: "Legs heavy" }), Message.SubmittedDeclaration()).model),
      // The fieldset disables every field and the button in it.
      Scene.expect(Scene.role("group")).toHaveAttr("disabled", "true"),
    ));

  it("ignores an edit that arrives while it saves, in the update too", () => {
    const saving = update(fill({ comments: "Legs heavy" }), Message.SubmittedDeclaration()).model;
    const edited = update(saving, Message.UpdatedDeclaration({ field: "comments", value: "Legs heavy, slept badly" }));
    expect(edited.model).toBe(saving);
    // Once it has saved the form is open again.
    const saved = update(saving, Message.SavedDeclaration()).model;
    expect(update(saved, Message.UpdatedDeclaration({ field: "mood", value: "2" })).model.declaration.mood).toMatchObject({ value: "2" });
  });

  it("reads the history again when it saved during a read that may predate it", () => {
    const reading = { ...onProfile, history: AsyncData.Loading() } as Model;
    const saving = update(fill({ mood: "3" }), Message.SubmittedDeclaration()).model;
    const saved = update({ ...saving, history: reading.history }, Message.SavedDeclaration());
    // The read under way isn't started twice…
    expect(saved.commands ?? []).toEqual([]);
    expect(saved.model.historyOutdated).toBe(true);
    // …but once it answers, the history is read again, keeping that answer on screen meanwhile.
    const range = { oldest: Day.make("2026-10-13"), newest: today };
    const history = Schema.decodeUnknownSync(IntervalsHistory)({ activities: [], wellness: [], athlete: { name: "Ana", weight: 61, ftp: 230 } });
    const answered = update(saved.model, Message.SettledLoadIntervals({ range, result: Result.succeed(history) }));
    expect(answered.commands?.map((c) => [c.name, c.args])).toEqual([["LoadIntervals", { range }]]);
    expect(answered.model.history).toEqual(History.Refreshing({ data: history }));
    expect(answered.model.historyOutdated).toBe(false);
  });

  it("leaves blank fields alone: they are optional", () => {
    expect(fill({ weight: "  " }).declaration.weight).toEqual(FieldValidation.NotValidated({ value: "  " }));
  });
});
