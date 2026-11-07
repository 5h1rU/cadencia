import * as Domain from "@alchemy.run/domain";
import { MessageId } from "./Message.id.ts";

/** A reply names a message the athlete never sent in this conversation. */
export class UnknownMessage extends Domain.Rejection("UnknownMessage", { messageId: MessageId }, { httpApiStatus: 409 }) {}
