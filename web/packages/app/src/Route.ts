import { pipe } from "effect/Function";
import * as Schema from "effect/Schema";
import { Route } from "foldkit";
import { defineRouteUnion, literal } from "foldkit/route";

/**
 * The web's pages, one per section. The paths are in Spanish, like the rest of
 * the web; `/api`, `/auth` and `/v1` belong to the server and are never pages.
 */
export const AppRoute = defineRouteUnion({
  Home: {},
  Coach: {},
  Plan: {},
  History: {},
  Profile: {},
  NotFound: { path: Schema.String },
});
export type AppRoute = typeof AppRoute.Type;

export const homeRouter = pipe(Route.root, Route.mapTo(AppRoute.Home));
export const coachRouter = pipe(literal("coach"), Route.mapTo(AppRoute.Coach));
export const planRouter = pipe(literal("plan"), Route.mapTo(AppRoute.Plan));
export const historyRouter = pipe(literal("historial"), Route.mapTo(AppRoute.History));
export const profileRouter = pipe(literal("perfil"), Route.mapTo(AppRoute.Profile));

/** The page a URL shows; anything else is `NotFound`, with the path that was asked for. */
export const routeOf = Route.parseUrlWithFallback(
  Route.oneOf(homeRouter, coachRouter, planRouter, historyRouter, profileRouter),
  AppRoute.NotFound,
);
