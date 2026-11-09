import { AthleteCoachApi } from "@cadencia/coach/AthleteCoachApi.api";
import { AthletePlanningApi } from "@cadencia/planning/AthletePlanningApi.api";
import type * as Domain from "@alchemy.run/domain";
import * as DomainFoldkit from "@alchemy.run/domain/Foldkit";

export type Clients = Domain.Api.ClientKey<"AthletePlanningApi"> | Domain.Api.ClientKey<"AthleteCoachApi">;
export const PlanningClient = DomainFoldkit.make(AthletePlanningApi);
export const CoachClient = DomainFoldkit.make(AthleteCoachApi);
