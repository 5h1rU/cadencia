import { describe, expect, it } from "@effect/vitest";
import { Navigation } from "foldkit";
import * as Scene from "foldkit/scene";
import { LoadPage, NavigateInternal } from "../src/command.ts";
import { Message } from "../src/message.ts";
import { AppRoute, historyRouter, routeOf } from "../src/route.ts";
import { viewTransition } from "../src/transition.ts";
import { update } from "../src/update.ts";
import { view } from "../src/view.ts";
import { signedIn, urlOf, visit } from "./fixture.ts";

describe("the web's pages", () => {
  it("each have a URL, and any other path is not found", () => {
    expect(["/", "/coach", "/plan", "/history", "/profile"].map((path) => routeOf(urlOf(path))._tag)).toEqual([
      "Home",
      "Coach",
      "Plan",
      "History",
      "Profile",
    ]);
    expect(routeOf(urlOf("/elsewhere"))).toEqual(AppRoute.NotFound({ path: "/elsewhere" }));
    expect(historyRouter()).toBe("/history");
  });

  it("move between pages without reloading, and leave the server's pages to the server", () => {
    const internal = (path: string) => Message.ClickedLink({ request: Navigation.UrlRequest.Internal({ url: urlOf(path) }) });
    const sent = (message: Message) => update(signedIn, message).commands?.map((c) => [c.name, c.args]);
    expect(sent(internal("/plan"))).toEqual([[NavigateInternal.name, { url: "http://localhost/plan" }]]);
    expect(sent(internal("/auth/intervals/start"))).toEqual([[LoadPage.name, { href: "http://localhost/auth/intervals/start" }]]);
    expect(update(signedIn, visit("/plan")).model.route).toEqual(AppRoute.Plan());
  });

  it("say so when a page doesn't exist, with a way back", () =>
    Scene.scene(
      { update, view },
      Scene.given(update(signedIn, visit("/elsewhere")).model),
      Scene.expect(Scene.text("Esta página no existe")).toExist(),
      Scene.expect(Scene.role("link", { name: "Volver a hoy" })).toExist(),
    ));

  it("slide in the direction of the navigation when they change, and nothing else animates", () => {
    const on = (path: string) => update(signedIn, visit(path)).model;
    const moving = (from: string, to: string) =>
      viewTransition({ previousModel: on(from), model: on(to), message: visit(to) });
    expect(moving("/", "/plan")).toEqual({ types: ["forward"] });
    expect(moving("/profile", "/coach")).toEqual({ types: ["backward"] });
    // A page outside the navigation cross-fades; staying on a page, or any other Message, doesn't animate.
    expect(moving("/plan", "/elsewhere")).toBe(true);
    expect(moving("/plan", "/plan")).toBe(false);
    expect(viewTransition({ previousModel: on("/"), model: on("/plan"), message: Message.ClickedRetire() })).toBe(false);
  });

  it("mark the page you are on in the navigation", () =>
    Scene.scene(
      { update, view },
      Scene.given(update(signedIn, visit("/profile")).model),
      Scene.expect(Scene.role("link", { name: "Perfil" })).toHaveAttr("aria-current", "page"),
    ));
});
