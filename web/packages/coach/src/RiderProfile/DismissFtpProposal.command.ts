import { FtpWatts } from "@cadencia/athlete/Measures";
import { AthleteId } from "@cadencia/identity/Athlete.id";
import { NotYours } from "@cadencia/identity/NotYours.rejection";
import { Session } from "@cadencia/identity/Session.middleware";
import * as Domain from "@alchemy.run/domain";

export class FtpProposalDismissed extends Domain.Event("FtpProposalDismissed", { ftp: FtpWatts }) {}

/** The athlete turns down an FTP the coach proposed. Needs no AI. */
export class DismissFtpProposal extends Domain.Command("DismissFtpProposal", {
  target: AthleteId,
  middleware: [Session],
  input: { ftp: FtpWatts },
  events: [FtpProposalDismissed],
  rejects: [NotYours],
}) {}
