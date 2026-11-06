import * as Domain from "@alchemy.run/domain";
import { MessageId } from "./Message.id.ts";

/** That message has no intent waiting for the athlete's answer. */
export class NoOpenIntent extends Domain.Rejection("NoOpenIntent", { messageId: MessageId }, { httpApiStatus: 409 }) {}
