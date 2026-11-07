import { FtpWatts } from "@cadencia/athlete/Measures";
import { NotYours } from "@cadencia/identity/NotYours.rejection";
import { mustOwn } from "@cadencia/identity/owns";
import { Session } from "@cadencia/identity/Session.middleware";
import * as Domain from "@alchemy.run/domain";
import * as Effect from "effect/Effect";
import * as Schema from "effect/Schema";
import { ModelName } from "../Provenance.ts";
import { RiderProfile } from "./RiderProfile.aggregate.ts";
import { RiderReport } from "./RiderReport.ts";

/** The latest profile and the FTP proposals the athlete turned down. */
export class RiderProfileCard extends Domain.View("RiderProfileCard", {
  from: [RiderProfile],
  key: RiderProfile,
  middleware: [Session],
  rejects: [NotYours],
  state: Schema.Struct({
    report: Schema.NullOr(RiderReport),
    model: Schema.NullOr(ModelName),
    dismissedFtp: Schema.NullOr(FtpWatts),
  }),
  // Bump when the state or how it folds changes, so the view is rebuilt from its events.
  version: 1,
  initial: { report: null, model: null, dismissedFtp: null },
  evolve: {
    ProfileRecorded: (v, e) => ({ ...v, report: e.report, model: e.model }),
    FtpProposalDismissed: (v, e) => ({ ...v, dismissedFtp: e.ftp }),
  },
  validate: Effect.fn(function* (request) {
    yield* mustOwn(request.key.id);
  }),
}) {}
