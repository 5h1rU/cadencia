import * as Domain from "@alchemy.run/domain";
import * as Effect from "effect/Effect";
import { Planner } from "../Planner.external.ts";
import { IntentAccepted } from "./AcceptIntent.command.ts";
import { Conversation } from "./Conversation.aggregate.ts";
import { RecordIntentOutcome } from "./RecordIntentOutcome.command.ts";

/** Whenever the athlete accepts an intent, ask the plan to apply it, and record what it did. */
export class IntentApplier extends Domain.Policy("IntentApplier", {
  from: Conversation,
  on: [IntentAccepted],
}) {}

export const IntentApplierLive = IntentApplier.toLayer(
  Effect.gen(function* () {
    const planner = yield* Planner;
    const conversations = yield* Conversation;
    return Effect.fn(function* ({ source, event }) {
      const answer = yield* planner.reviseWeek({ planId: event.intent.planId, limits: event.intent.limits });
      yield* conversations.send(source, new RecordIntentOutcome({ messageId: event.messageId, ...answer }));
    });
  }),
);
