# Cadencia — agent notes

## Build & test

- `CadenciaCore/` is a plain SwiftPM package with no Apple-framework imports. Test it with `swift test` in that directory (Swift 6 toolchain; works on Linux). Keep it that way: anything needing HealthKit, CoreBluetooth, SwiftUI or Speech belongs in the app target.
- The app target (`Cadencia/`, `Cadencia.xcodeproj`) only builds in Xcode 16+ on macOS. If the hand-written pbxproj misbehaves, `xcodegen generate` from `project.yml` recreates it.
- No Xcode in orbs: when editing app sources without a Mac, compile-check what you can by moving logic into `CadenciaCore` and testing it there.
- `web/` is a pnpm workspace (TypeScript, Effect 4, `@alchemy.run/domain` on Cloudflare). From `web/`: `npx pnpm@10 install`, `npx pnpm@10 test`, `npx pnpm@10 typecheck`. See `web/README.md`.
- `web/` pins Alchemy `2.0.0-beta.85`. Its API is older than the alchemy plugin's docs: views take `validate` inline (no `toLayer`), Apis have no `queries`, commands take no `{ description }`. Check the installed sources or the `v2.0.0-beta.85` tag's `examples/cloudflare-domain` before following the plugin.
- Domain packages (`kernel`, `planning`, `coach`) import only `effect`, `@alchemy.run/domain` and `@cadencia/kernel`. Infrastructure (Cloudflare, HTTP, Intervals, D1) lives in `server`. Coach never imports Planning: it reaches it through the `Planner` external system.
- Planning and Coach share one Worker. Build every Api over its own model's internals (`overPlanning`/`overCoach` in `web/packages/server/src/Hosting.ts`); otherwise the second model hides the first.
- Specify behaviour with Alchemy stories (`Story.make`) in each domain package; server tests host both models in memory with the real `Planner`.

## Conventions

- Intervals.icu is the system of record. The iOS app persists a single `AppState` JSON plus one JSON per ride.
- The web backend (`web/`) stores only what Intervals has no field for: plan intent and phases, conversation, consultations, daily decisions and the AI rider profile, as events in Durable Objects (EU jurisdiction). Intervals OAuth tokens live encrypted in D1, outside the events, so they can be deleted.
- The AI runs only in Cadencia iOS, with the athlete's own ChatGPT plan (Sign in with ChatGPT is documented for local, open-source apps). The backend never calls an LLM: iOS records each interpretation (model, evidence, fingerprint) through `CoachDeviceApi`, and Planning accepts or refuses it. The web writes only what needs no AI. Until iOS switches to the backend's `/v1` API it still keeps that memory locally.
- Anything Intervals has a native field for (wellness feel/sleep/motivation/mood/stress/injury/comments, weight, height, units, Ride FTP, weekly availability, goal event, time away, other training, planned rides' indoor/FTP/type) is only cached in `AppState`. Local edits go into `IntervalsOutbox` (or `CalendarSync` for calendar entries) and are read back on refresh; Intervals wins unless a local change is still unsent. Plan intent, phases, conversation, coach decisions and evaluations stay local.
- All mutation goes through `AppModel` methods; views read `model.state` and never write it directly.
- User-facing strings are English source keys with Spanish in `Cadencia/Resources/Localizable.xcstrings`. Use `LocalizedStringKey` for view text and `String(localized:)` for strings handed to non-view APIs.
- Uploads must stay idempotent: every ride has an `externalID`, and an `.uncertain` ledger entry is reconciled by that id before any re-upload.
- Readiness can soften a day's prescription, never harden it beyond the plan. On the backend this rule lives only in Planning (`web/packages/planning/src/Plan/PrescriptionRules.ts`).
