import { AthleteId } from "@cadencia/kernel/Athlete.id";
import { inputOf, mustOwn } from "@cadencia/kernel/owns";
import * as Domain from "@alchemy.run/domain";
import * as Effect from "effect/Effect";
import * as Schema from "effect/Schema";
import {
  AutomaticAttemptUsed,
  DismissFtpProposal,
  FtpProposalDismissed,
  ProfileAttempted,
  ProfileRecorded,
  RecordProfile,
  RecordProfileAttempt,
} from "./RiderProfile.commands.ts";

/** What the coach has learned about the rider's profile, keyed by athlete. */
export class RiderProfile extends Domain.Aggregate("RiderProfile", {
  id: AthleteId,
  state: Schema.Struct({ attempted: Schema.Boolean, hasReport: Schema.Boolean }),
  initial: { attempted: false, hasReport: false },
  commands: [RecordProfileAttempt, RecordProfile, DismissFtpProposal],
  decide: {
    RecordProfileAttempt: Effect.fn(function* (state, cmd, { id }) {
      yield* mustOwn(id);
      if (cmd.automatic && (state.attempted || state.hasReport)) return yield* new AutomaticAttemptUsed();
      return [new ProfileAttempted(inputOf(cmd))];
    }),
    RecordProfile: Effect.fn(function* (_, cmd, { id }) {
      yield* mustOwn(id);
      return [new ProfileRecorded(inputOf(cmd))];
    }),
    DismissFtpProposal: Effect.fn(function* (_, cmd, { id }) {
      yield* mustOwn(id);
      return [new FtpProposalDismissed(inputOf(cmd))];
    }),
  },
  evolve: {
    ProfileAttempted: (s) => ({ ...s, attempted: true }),
    ProfileRecorded: (s) => ({ ...s, hasReport: true }),
    FtpProposalDismissed: (s) => s,
  },
}) {}
