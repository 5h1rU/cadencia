import { Title } from "@cadencia/kernel/Text";
import * as Schema from "effect/Schema";
import { FtpWatts, Kilograms } from "./Measures.ts";

/** What Intervals.icu knows about the athlete that the web shows. Null when Intervals has none Cadencia can use. */
export const AthleteMeasures = Schema.Struct({
  /** The name the athlete gave Intervals. */
  name: Schema.NullOr(Title),
  weight: Schema.NullOr(Kilograms),
  /** The FTP of the athlete's Ride sport settings. */
  ftp: Schema.NullOr(FtpWatts),
});
export type AthleteMeasures = typeof AthleteMeasures.Type;

