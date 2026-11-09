import * as Option from "effect/Option";
import { AsyncData, Url } from "foldkit";
import { emptyDeclaration, emptyMove, emptyRequirement } from "./domain/form.ts";
import { Flags, Model } from "./model.ts";
import { routeOf } from "./route.ts";
import { historyOpened, type Return } from "./update.ts";

/** A live view at start: waiting for its first snapshot when signed in, not watched otherwise. */
const watching = (flags: Flags) => (flags.athleteId === null ? AsyncData.Idle() : AsyncData.Loading());

/** The app as it opens on `url`: a reload or a link to the history or profile page reads the history at once. */
export const init = (flags: Flags, url: Url.Url): Return =>
  historyOpened(
    Model.make({
      athleteId: flags.athleteId,
      unreachable: flags.unreachable,
      today: flags.today,
      route: routeOf(url),
      commandIds: { session: flags.pageLoad, sent: 0 },
      readsOnline: true,
      readRetries: 0,
      plan: watching(flags),
      decision: watching(flags),
      thread: watching(flags),
      profile: watching(flags),
      history: AsyncData.Idle(),
      move: emptyMove,
      requirement: emptyRequirement(flags.today),
      declaration: emptyDeclaration,
      savingDeclaration: false,
      historyOutdated: false,
      confirmRetire: false,
      inFlight: Option.none(),
      needsReconnect: false,
      notice: Option.none(),
      error: Option.none(),
    }),
  );
