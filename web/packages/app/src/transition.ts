import * as Array from "effect/Array";
import * as Match from "effect/Match";
import * as Option from "effect/Option";
import { AsyncData, type Runtime } from "foldkit";
import { Message } from "./message.ts";
import { historyOnScreen, Model } from "./model.ts";
import { AppRoute } from "./route.ts";
import { PAGES } from "./view.ts";

type Animation = ReturnType<Runtime.ViewTransitionConfig<Model, Message>>;

/** Where a page sits in the navigation; a page outside it has no place there. */
const positionOf = (route: AppRoute) => Array.findFirstIndex(PAGES, ([tag]) => tag === route._tag);

/** Both pages have a place in the navigation, and the second comes later. */
const furtherAlong = (places: Option.Option<readonly [number, number]>) =>
  Option.exists(places, ([before, after]) => after > before);

/** Moving to another page slides it forward or back along the navigation; a page outside it just cross-fades. */
const pageMove = (from: AppRoute, to: AppRoute): Animation =>
  Match.value({ samePage: from._tag === to._tag, places: Option.all([positionOf(from), positionOf(to)]) }).pipe(
    Match.withReturnType<Animation>(),
    Match.when({ samePage: true }, () => false),
    Match.when({ places: Option.isNone }, () => true),
    Match.when({ places: furtherAlong }, () => ({ types: ["forward"] })),
    Match.orElse(() => ({ types: ["backward"] })),
  );

/**
 * The history arriving on screen: its first answer grows the placeholders
 * into the cards (`reveal`), and a refresh brings new activities in and lets
 * the ones that moved slide to their place (`refresh`). An answer that changed
 * nothing, or brought only a problem, renders plainly.
 */
const historyArrival = (previous: Model, model: Model): Animation =>
  Match.value({
    onScreen: historyOnScreen(model),
    changed: previous.history !== model.history,
    before: previous.history,
    after: model.history,
  }).pipe(
    Match.withReturnType<Animation>(),
    Match.when({ onScreen: true, changed: true, before: AsyncData.hasData, after: AsyncData.hasData }, () => ({ types: ["refresh"] })),
    Match.when({ onScreen: true, changed: true, after: AsyncData.hasData }, () => ({ types: ["reveal"] })),
    Match.orElse(() => false),
  );

/** Which renders animate, where the browser can: moving between pages and the history arriving. Nothing else does. */
export const viewTransition: Runtime.ViewTransitionConfig<Model, Message> = ({ previousModel, model, message }) =>
  Match.value(message).pipe(
    Match.withReturnType<Animation>(),
    Match.tag("ChangedUrl", () => pageMove(previousModel.route, model.route)),
    Match.tag("SettledLoadIntervals", () => historyArrival(previousModel, model)),
    Match.orElse(() => false),
  );
