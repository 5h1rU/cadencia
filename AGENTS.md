# Cadencia — agent notes

## Build & test

- `CadenciaCore/` is a plain SwiftPM package with no Apple-framework imports. Test it with `swift test` in that directory (Swift 6 toolchain; works on Linux). Keep it that way: anything needing HealthKit, CoreBluetooth, SwiftUI or Speech belongs in the app target.
- The app target (`Cadencia/`, `Cadencia.xcodeproj`) only builds in Xcode 16+ on macOS. If the hand-written pbxproj misbehaves, `xcodegen generate` from `project.yml` recreates it.
- No Xcode in orbs: when editing app sources without a Mac, compile-check what you can by moving logic into `CadenciaCore` and testing it there.

## Conventions

- Intervals.icu is the system of record. The app persists a single `AppState` JSON plus one JSON per ride; nothing else is stored server-side.
- Anything Intervals has a native field for (wellness feel/sleep/motivation/mood/stress/injury/comments, weight, height, units, Ride FTP, weekly availability, goal event, time away, other training, planned rides' indoor/FTP/type) is only cached in `AppState`. Local edits go into `IntervalsOutbox` (or `CalendarSync` for calendar entries) and are read back on refresh; Intervals wins unless a local change is still unsent. Plan intent, phases, conversation, coach decisions and evaluations stay local.
- All mutation goes through `AppModel` methods; views read `model.state` and never write it directly.
- User-facing strings are English source keys with Spanish in `Cadencia/Resources/Localizable.xcstrings`. Use `LocalizedStringKey` for view text and `String(localized:)` for strings handed to non-view APIs.
- Uploads must stay idempotent: every ride has an `externalID`, and an `.uncertain` ledger entry is reconciled by that id before any re-upload.
- Readiness can soften a day's prescription, never harden it beyond the plan.
