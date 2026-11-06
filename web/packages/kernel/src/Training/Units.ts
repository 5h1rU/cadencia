import * as Schema from "effect/Schema";

/** Whole minutes, within one day. */
export const Minutes = Schema.Int.pipe(Schema.check(Schema.isBetween({ minimum: 0, maximum: 1440 })), Schema.brand("Minutes"));
export type Minutes = typeof Minutes.Type;

/** Seconds, within one day. */
export const Seconds = Schema.Number.pipe(
  Schema.check(Schema.isFinite(), Schema.isBetween({ minimum: 0, maximum: 86_400 })),
  Schema.brand("Seconds"),
);
export type Seconds = typeof Seconds.Type;

/** An intensity as a fraction of FTP: 0.65 is 65 %. */
export const FtpFraction = Schema.Number.pipe(
  Schema.check(Schema.isFinite(), Schema.isBetween({ minimum: 0, maximum: 3 })),
  Schema.brand("FtpFraction"),
);
export type FtpFraction = typeof FtpFraction.Type;

/** Pedalling cadence, in revolutions per minute. */
export const CadenceRpm = Schema.Int.pipe(Schema.check(Schema.isBetween({ minimum: 20, maximum: 200 })), Schema.brand("CadenceRpm"));
export type CadenceRpm = typeof CadenceRpm.Type;

/** A distance, in kilometres. */
export const Kilometers = Schema.Number.pipe(
  Schema.check(Schema.isFinite(), Schema.isBetween({ minimum: 0, maximum: 2000 })),
  Schema.brand("Kilometers"),
);
export type Kilometers = typeof Kilometers.Type;
