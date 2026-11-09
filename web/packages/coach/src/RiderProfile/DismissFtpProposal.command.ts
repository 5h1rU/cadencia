import { FtpWatts } from "@cadencia/athlete/Measures";
import { AthleteId } from "@cadencia/identity/Athlete.id";
import { Authenticated } from "@cadencia/identity/Authenticated.middleware";
import { NotYours } from "@cadencia/identity/NotYours.rejection";
import * as Domain from "@alchemy.run/domain";

export class FtpProposalDismissed extends Domain.Event("FtpProposalDismissed", { ftp: FtpWatts }) {}

/** The athlete turns down an FTP the coach proposed. Needs no AI. */
export class DismissFtpProposal extends Domain.Command("DismissFtpProposal", {
  target: AthleteId,
  middleware: [Authenticated],
  input: { ftp: FtpWatts },
  events: [FtpProposalDismissed],
  rejects: [NotYours],
}) {}
