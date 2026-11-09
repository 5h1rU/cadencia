**Cadencia web — codebase review and handoff**

Review date: November 7, 2026 (America/Bogota). Scope: `web/`, including all seven workspace packages and the Alchemy stack. Status: analysis only; the proposed application changes have not been implemented.

**Assessment:** retain the architecture and prioritize correctness. The most valuable improvements concern plan constraints, concurrent calendar changes, and frontend save lifecycles. A framework rewrite is not indicated by this review.

Code references below are relative to the repository root. Line numbers describe the working tree reviewed on November 7 and may move as the code changes. Recheck each finding against the current code before implementing it.

The working tree already contained changes in these files when the review began:

- `Cadencia/Resources/Localizable.xcstrings`
- `web/packages/app/index.html`
- `web/packages/app/src/Cadencia.ts`
- `web/packages/app/test/Cadencia.test.ts`

The review included the working-tree versions. It did not modify application sources, commit changes, or deploy anything. This Markdown file is the review handoff.

The review compared current official documentation with the installed sources for Alchemy `2.0.0-beta.85` and Foldkit `0.170.0`. The installed version is authoritative when current documentation describes a newer API. In particular, beta.85 uses inline view validation, has no Api `queries`, and does not accept the newer command-description argument. Treat a framework upgrade as a separate, tested migration.

The package boundaries reviewed were:

| Package | Responsibility |
| --- | --- |
| `identity` | Actors, athlete identity, session middleware, ownership checks. |
| `kernel` | Terms shared by both contexts: days, plan identifiers, text, training values. |
| `athlete` | Intervals evidence, readiness, wellness, and measures. |
| `planning` | Plan intent, activation, constraints, prescriptions, and calendar publication policies. |
| `coach` | Recorded AI interpretations, conversations, consultations, daily decisions, and rider profiles. |
| `server` | Model hosting, HTTP APIs, sessions, OAuth, encrypted connections, and Intervals adapters. |
| `app` | Foldkit routes, live views, forms, and commands that require no AI. |

**Validation completed during the review:**

All commands below were run from `web/`.

| Command | Result |
| --- | --- |
| `npx pnpm@10 test` | 207 tests passed across all seven packages. |
| `npx pnpm@10 typecheck` | Passed, including the stack type check. |
| `npx pnpm@10 --filter @cadencia/app build` | Passed. One JavaScript chunk: 554.58 kB, 175.42 kB gzipped. Vite reported its chunk-size warning. |

Test counts were: identity 3, kernel 29, athlete 22, planning 34, coach 34, server 42, app 43.

Additional reproductions used inline execution against existing exported functions and fixtures, with mocked vendor responses where needed. They did not perform production Intervals writes or exercise deployed infrastructure. These probes were not added to the repository as regression tests. Passing checks establish the existing suite's result; they do not invalidate the uncovered cases below.

**Agent tooling checked and installed:**

- Alchemy Domain was already installed. Its guidance was checked alongside the skill bundled with beta.85.
- The official `foldkit`, `audit-program`, and `generate-program` skills were installed at user level from the `foldkit@0.170.0` release. No application dependency or lockfile upgrade was performed.
- Foldkit DevTools MCP was already present as `@foldkit/devtools-mcp` version `0.26.0`, with a repository `.mcp.json` entry. It was also registered in the reviewer's user-level Codex configuration.
- A direct MCP connection discovered two running local Cadencia browser runtimes and read their runtime status. No messages were dispatched, no replay was initiated, and no application mutation was performed through MCP. This confirms the local MCP connection, not an authenticated end-to-end application flow.
- Alchemy's documented MCP feature converts an application Api into agent tools. Exposing Cadencia through it would require application changes and remains a separate design decision. See [Alchemy MCP](https://alchemy.run/domain/mcp/).

User-level skills and MCP registration are local tooling configuration; this handoff does not imply those settings exist on the code owner's machine.

**Architecture and behavior worth preserving:**

- Planning and Coach are separate bounded contexts, with infrastructure outside the domain packages and automated import-boundary checks.
- Command decisions and view validation enforce ownership. Planning checks ownership again when Coach delegates through the Planner adapter.
- `overPlanning` and `overCoach` build each Api over the correct model's internals when both models share one Worker.
- Intervals remains the system of record. AI runs in iOS, while the backend records interpretations and enforces domain rules.
- External systems declare their errors. Calendar refusals become domain facts, while transient failures can be retried and redelivered.
- Deterministic external IDs prevent duplicate calendar entries on replay. Publication acknowledgements already compare the published session snapshot with current state.
- OAuth tokens are encrypted, redacted, and stored outside immutable events. Stack state preserves signing and encryption keys.
- Public application HTTP is declared with typed HttpApi schemas. iOS has its own domain Api surface and Swift-to-web contract fixtures.
- The frontend uses schema-defined Model/Message/update/view flow, stable command IDs, same-ID retries for unknown outcomes, and stale-command-result rejection.
- Existing stories and Scene assertions check observable behavior. Typed routes, stable row keys, labeled controls, visible focus styles, local-day rollover handling, and conversation source-key guards provide useful foundations.

The priorities below use **P1** for high-priority invariant or consistency failures and **P2** for other correctness defects. They describe review priority, not evidence of a production incident.

1. **P1 — Prescription validation can harden an already demanding session.**

   Evidence: `web/packages/planning/src/Plan/PrescriptionRules.ts:86`.

   The hardening restriction is conditional on `isEasy(session.kind)`. A decoded, valid 75-minute threshold session accepted a 60-minute VO2max workout at 130% FTP: `problemWith` returned `undefined`, meaning no refusal. The rule therefore protects easy sessions but does not fully enforce the stated invariant that readiness can soften a prescription without hardening it beyond the plan.

   Proposed improvement: define permitted transformations and intensity/dose bounds for every planned session kind, especially tempo, threshold, and opener sessions. Keep the rule in Planning.

   Regression coverage: exercise every planned-kind/proposed-kind combination and the relevant dose boundaries, including shorter but substantially more intense proposals.

2. **P1 — Moving a session bypasses the destination day's saved limits.**

   Evidence: `web/packages/planning/src/Plan/Plan.aggregate.ts:255`.

   `MoveSession` checks ownership, dates, and occupancy, then copies the session to the new day unchanged. Reproduced: record a 30-minute requirement for an empty Wednesday, then move Tuesday's 75-minute session there. The emitted session remains 75 minutes, and CalendarPublishing publishes it.

   Proposed improvement: evaluate destination requirements in the move decision and explicitly choose whether to refuse or conservatively adjust the session. Reconsider workouts whose purpose depends on their date, such as an opener before an event.

   Regression coverage: move provisional and concrete sessions onto constrained days; check the emitted session and the calendar operation.

3. **P1 — The current-plan view relies on ordering across independent plan streams.**

   Evidence: `web/packages/planning/src/Plan/CurrentPlan.view.ts:85`; related activation code at `web/packages/planning/src/ActivePlan/PlanActivation.policy.ts:10` and `web/packages/planning/src/ActivePlan/ActivePlan.aggregate.ts:17`.

   Every `PlanCreated` unconditionally replaces the displayed plan. Alchemy guarantees order within a source, but not across different sources. Folding newer plan B, then older plan A and A's retirement, leaves CurrentPlan displaying retired A while B should remain current. This was reproduced through the real view folds, not observed in production. Activation policies also process the separate plan streams independently, so simply following whichever activation arrives last does not establish creation order.

   Proposed improvement: make athlete-scoped activation authoritative, with an explicit generation or equivalent ordering rule. The view must tolerate older plan data arriving after the current activation, including on rebuild and backfill.

   Regression coverage: permute interleavings from two plans while preserving each source's own order; verify the current pointer, view, and retirement behavior agree. See [Alchemy order and partitions](https://alchemy.run/domain/model/#order-and-partitions).

4. **P2 — Duplicate day limits can undo an unavailable day.**

   Evidence: `web/packages/planning/src/Plan/Plan.aggregate.ts:123` and `web/packages/planning/src/Plan/ReviseWeek.command.ts:24`.

   `sessionsWithin` evaluates each limit against the original session, then `replaceSessions` keeps the final duplicate session ID. Reproduced: an unavailable limit followed by a 60-minute limit for the same 75-minute session emits skipped/0 and then provisional/60. The final state contains a ride on the unavailable day. The command accepts an array without unique-day validation.

   Proposed improvement: reject duplicate days or combine their constraints conservatively before generating changes.

   Regression coverage: conflicting and identical duplicate limits, in both orders; an unavailable limit must not be weakened by a later entry.

5. **P2 — Stale calendar observations can invalidate a newer publication.**

   Evidence: `web/packages/server/src/Intervals/ChangeSync.ts:36`, `web/packages/planning/src/Plan/RecordExternalChange.command.ts:24`, and `web/packages/planning/src/Plan/Plan.aggregate.ts:304`.

   Synchronization reads a plan snapshot, calls Intervals, and sends only `{ externalId, change }`. It does not carry the observed publication revision. If a move and republication complete before the observation is recorded, the session can be `published` again and accept stale evidence. Reproduced with `Plan.predict`: an old removal observation marked a moved and republished session as removed in Intervals.

   Proposed improvement: include the observed publication revision or fingerprint and ignore observations that no longer match the current session.

   Regression coverage: pause the vendor read, move and republish the session, then deliver the old response; it must not transfer ownership or mark the newer publication removed.

6. **P2 — Calendar synchronization misses workout edits and subsequent deletions.**

   Evidence: `web/packages/server/src/Intervals/ChangeSync.ts:16`, `web/packages/server/src/Intervals/ChangeSync.ts:38`, and `web/packages/server/src/Intervals/IntervalsHttp.ts:55`.

   There are two gaps in the actual synchronization path:

   - Change detection compares only day, name, and duration. A workout-description or power-target edit that preserves those fields is treated as untouched. A direct description-only probe returned `null`; the session remains Cadencia-owned and a later write can overwrite the athlete's edit.
   - Synchronization watches only `published` sessions. Once a session becomes `changedInIntervals`, a later deletion is ignored. The aggregate supports changed-to-removed transitions, but this webhook path cannot reach them.

   Proposed improvement: compare a normalized representation of the fields Cadencia writes, including workout content, and continue checking externally changed sessions for disappearance. Define normalization to avoid treating harmless vendor formatting as an athlete edit.

   Regression coverage: workout-content changes with identical name/duration; changed-then-deleted sessions through the actual webhook/sync path.

7. **P2 — Publication can be recorded without a valid acknowledgement.**

   Evidence: `web/packages/server/src/Intervals/IntervalsCalendar.ts:71` and `web/packages/planning/src/Plan/CalendarPublishing.policy.ts:45`.

   The adapter returns `{ published: false }` for a malformed successful JSON response, but the policy ignores that result and records publication anyway. An empty array also passes the acknowledgement schema. Mocked adapter responses produced `200 [] -> published: true` and `200 {} -> published: false`; the policy treats both completed calls as publication success.

   Proposed improvement: make successful adapter completion mean that the requested event was confirmed. Invalid or missing acknowledgements should produce an appropriate declared failure instead of a success-shaped boolean the caller can ignore.

   Regression coverage: real adapter plus policy, covering valid acknowledgement, empty array, malformed body, and transient/permanent HTTP failures.

8. **P2 — Revoked authorization is presented as an Intervals outage.**

   Evidence: `web/packages/server/src/Intervals/AthleteReads.ts:98`.

   Every vendor failure becomes `IntervalsUnavailable`, including 401 responses. A mocked 401 reproduced that result. The calendar adapter already distinguishes authentication failures, and the web API has an `IntervalsNotConnected` error, so the read path loses information the frontend needs to offer reconnection.

   Proposed improvement: translate authentication failures consistently, distinguish missing permissions where possible, and reserve retry messaging for transient failures.

   Regression coverage: revoked credentials, missing scopes, rate limits, transport failures, and vendor 5xx responses across reads and wellness writes.

9. **P2 — Successful saves erase edits made while saving.**

   Evidence: `web/packages/app/src/Cadencia.ts:801`, `web/packages/app/src/Cadencia.ts:1421`, and related move/requirement handlers at `web/packages/app/src/Cadencia.ts:763`.

   Inputs remain editable while submission is pending; only the submit button is disabled. `SavedDeclaration` then clears the whole form. Reproduced against the actual `update`: submit a declaration, type a new comment while waiting, and deliver success. The new unsaved comment changes to an empty string. Move and requirement forms use the same unconditional-reset pattern.

   Proposed improvement: disable the full form during submission, or retain the submitted snapshot/revision and clear only fields that still match it.

   Regression coverage: edits between submission and success, including a failed request and retry. Preserve the existing guards against stale command replies.

10. **P2 — A wellness save can lose its cache invalidation.**

    Evidence: `web/packages/app/src/Cadencia.ts:613` and `web/packages/app/src/Cadencia.ts:801`.

    `SavedDeclaration` calls `historyChanged`, which uses `AsyncData.revalidate`. In pinned Foldkit 0.170.0 this skips `Loading` and `Refreshing`. Reproduced: open Profile to start its initial read, save wellness before that read settles, then receive save success. The model remains loading and emits zero refresh commands. A response that observed Intervals before the mutation can become the accepted cache without a guaranteed post-save read.

    Proposed improvement: track an invalidation generation/dirty flag and perform a fresh read after the pending request settles, or replace the request with identity checks that reject pre-save responses.

    Regression coverage: both completion orders for a read overlapping a mutation, including failures and navigation during the overlap.

11. **P2 — A decision ID accepts impossible dates that later throw.**

    Evidence: `web/packages/coach/src/DailyDecision/DailyDecision.id.ts:6` and `web/packages/coach/src/DailyDecision/DailyDecision.id.ts:15`.

    The composite ID validates date-shaped digits rather than a valid calendar day. Schema decoding accepts `i100:2026-02-31`, but `dayOfDecision` calls `Day.make` and throws. This allows an invalid target through the first validation boundary before it becomes a defect.

    Proposed improvement: validate the embedded date using the semantic `Day` schema at the input boundary.

    Regression coverage: impossible dates and valid leap days through the composite schema and the HTTP command boundary.

**Broader improvement opportunities:**

| Area | Evidence and proposed direction |
| --- | --- |
| Frontend ownership | `web/packages/app/src/Cadencia.ts:261` begins a global Model for five routes, four live-view lifecycles, all forms, and mutation bookkeeping. The file is 1,539 lines. Extract independently stateful features, starting with wellness submission and plan editing, into Foldkit Submodels; keep stateless rendering in helpers. Keep importing canonical domain schemas. |
| Session startup | `web/packages/app/src/entry.ts:15` converts every session-check failure to signed out, including transport, server, and decoding failures. Represent authenticated, unauthenticated, and unavailable separately, with a bounded startup request and a retry path. |
| Integration coverage | `web/packages/server/test/worker.ts` uses memory connections, an accepting fake calendar, and `Domain.InMemory`. Retain those tests and add calendar-adapter contracts plus one workerd flow covering real D1 layers, bindings/migrations, routing, Durable Objects, and WebSockets. A bounded staging smoke test can supply additional deployment evidence when authorized. |
| Continuous checks | No runnable frontend lint/format gate or repository CI workflow was located. Add repeatable CI checks and evaluate the official Foldkit lint rules as a separate project change. No lint gate was run in this review. |
| Accessibility | `web/packages/app/src/Cadencia.ts:1114` already associates field errors using ARIA, but failed submission has no error announcement/focus policy. The document at line 1491 has a constant title and no `main` landmark. Add route-specific titles, a main landmark, and deliberate focus/announcement behavior for validation and navigation. |
| Cancellation and deadlines | `web/packages/server/src/Intervals/IntervalsHttp.ts:29` calls fetch without a propagated abort signal or an explicit deadline. Define request budgets or use the Effect HTTP client, particularly because webhook acknowledgement waits for synchronization. |
| Operations | `web/packages/server/src/CadenciaWorker.ts` already provides Cloudflare telemetry. Add alerts for persistent publication failures, synchronization failures, and retry/backlog age. Browser-to-server connected traces need an appropriate OTLP destination. |
| Bundle size | The production build emits one 554.58 kB JavaScript chunk, 175.42 kB gzipped. Measure startup on target devices and networks before deciding whether route-level code splitting is worthwhile. This build result alone does not establish a user-visible performance problem. |

Foldkit's [architecture and AI overview](https://foldkit.dev/ai/overview) describes Model/Message/update boundaries and stateful Submodels. Its [pinned realtime subscription exemplar](https://github.com/foldkit/foldkit/blob/foldkit%400.170.0/packages/typing-game/client/src/page/room/subscription.ts) is a useful comparison. Alchemy's [API-testing guidance](https://alchemy.run/domain/testing-apis/) describes the additional integration boundary, and its [observability guidance](https://alchemy.run/domain/observability/) describes the limits of Cloudflare's per-event traces and browser-span collection.

**Important review exclusions and false positives:**

- Direct aggregate sends inside Alchemy policies already receive deterministic command IDs from the pinned engine. Their lack of an explicit ID is not itself a defect. The explicit `requestFor(envelope)` used across the Planner adapter is appropriate.
- In beta.85, converting `CalendarUnavailable` into a defect does not bypass the configured policy retry mechanism. Do not remove that behavior based solely on current-documentation assumptions.
- Existing Story and Scene tests are substantive. The absence of a file literally named `scene.test.ts` is not a finding.
- Fractional weight entry was not established as broken. Foldkit synchronizes controlled input value/defaultValue, affecting the browser's numeric step base; omitting `step` alone was insufficient evidence.
- No authentication exploit was demonstrated. The real iOS sign-in uses `ASWebAuthenticationSession`; a generic custom-scheme interception claim would overstate this review's evidence.

**Suggested implementation sequence for the code owner:**

1. Reproduce and pin the domain-invariant findings: prescription hardening, destination-day requirements, activation ordering, and duplicate limits.
2. Make calendar synchronization revision-aware, close change-detection gaps, and tighten adapter acknowledgement contracts.
3. Correct frontend submission and invalidation lifecycles, then extract stateful ownership boundaries where they simplify those behaviors.
4. Add integration/CI coverage and consistent session/vendor error handling.
5. Address accessibility, operational alerts, and measured performance opportunities.

For later changes, follow `AGENTS.md`: bump view versions when folds/state change, preserve decoding of stored events, and update both sides of the Swift/backend contract when the wire schema changes. Do not edit the generated Swift client by hand.

The user authorized analysis and agent-tool installation for this review. This report records proposed improvements; implementation remains separate work.
