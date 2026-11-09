import * as Domain from "@alchemy.run/domain";
import { Actor } from "./Actor.ts";

/** Who is making the current request. `Authenticated` provides it; policies provide a system actor. */
export class CurrentActor extends Domain.RequestContext<CurrentActor>()(
  "Cadencia/CurrentActor",
  Actor,
) {}
