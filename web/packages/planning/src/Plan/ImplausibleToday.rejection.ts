import { Day } from "@cadencia/kernel/Calendar/Day";
import * as Domain from "@alchemy.run/domain";

/**
 * The day a client says is today is too far from the server's clock. A Day is
 * the athlete's local day, which the domain has no time zone to compute, so the
 * athlete's client sends it; it can differ from the UTC date by one day at most.
 */
export class ImplausibleToday extends Domain.Rejection("ImplausibleToday", { today: Day }, { httpApiStatus: 422 }) {}
