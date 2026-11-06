import * as Domain from "@alchemy.run/domain";
import * as Schema from "effect/Schema";

/** That message has no intent waiting for the athlete's answer. */
export class NoOpenIntent extends Domain.Rejection("NoOpenIntent", { messageId: Schema.String }, { httpApiStatus: 409 }) {}
