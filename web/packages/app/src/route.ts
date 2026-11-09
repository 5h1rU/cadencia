import { pipe } from "effect/Function";
import * as Schema from "effect/Schema";
import { Route } from "foldkit";
import { defineRouteUnion, literal } from "foldkit/route";

/**
 * The web's pages, one per section. Paths and parameters are English, like the
 * code; only what the athlete reads is Spanish. `/api`, `/auth` and `/v1`
 * belong to the server and are never pages.
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
export const historyRouter = pipe(literal("history"), Route.mapTo(AppRoute.History));
export const profileRouter = pipe(literal("profile"), Route.mapTo(AppRoute.Profile));

/** The page a URL shows; anything else is `NotFound`, with the path that was asked for. */
export const routeOf = Route.parseUrlWithFallback(
  Route.oneOf(homeRouter, coachRouter, planRouter, historyRouter, profileRouter),
  AppRoute.NotFound,
);

/** The path that shows `route`. */
export const hrefOf = (route: AppRoute): string =>
  AppRoute.match(route, {
    Home: () => homeRouter(),
    Coach: () => coachRouter(),
    Plan: () => planRouter(),
    History: () => historyRouter(),
    Profile: () => profileRouter(),
    NotFound: ({ path }) => path,
  });
