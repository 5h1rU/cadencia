# Cadencia

Native iOS cycling-training app that keeps **Intervals.icu as the system of record** and replaces the TrainerRoad / TrainingPeaks / ChatGPT juggling with one place that:

- reads your Intervals.icu data (athlete, wellness, activities, power curve) and Apple Health (HRV, resting HR, sleep),
- turns that into a daily readiness verdict (rest / go easy / ready / go hard) and a concrete workout for today, with a target and a ceiling,
- lets you plan around a goal or an event, but only keeps the coming week concrete; later weeks are intentions,
- takes voice or text notes to the coach ("Saturday I have a 120 km group ride, Thursday only 45 minutes") and revises the week,
- runs structured workouts on a smart trainer over Bluetooth (FTMS, ERG) with a heart-rate band and optional power meter,
- saves the ride locally, uploads it to Intervals.icu exactly once, writes it to Apple Health, and pushes RPE/feel back,
- estimates FTP from sustained efforts and asks before changing zones.

## Layout

| Path | What |
| --- | --- |
| `CadenciaCore/` | Swift package, no Apple-framework dependencies. Domain models, readiness, prescriber, plan builder, week reviser, coach engines (heuristic + LLM), FTP estimator, Intervals.icu client + OAuth, TCX encoder, upload ledger, ride engine, BLE protocol parsing (FTMS, HR, Cycling Power). Unit-tested; builds on Linux. |
| `Cadencia/` | SwiftUI app target. `App/` (state + model), `Services/` (HealthKit, CoreBluetooth, Speech, Keychain, JSON store, OAuth session), `Features/` (Today, Coach, Plan, Ride, Settings), `Support/`, `Resources/` (string catalog en → es). |
| `Config/` | `Info.plist` (usage descriptions, `cadencia://` URL scheme) and entitlements (HealthKit). |
| `Cadencia.xcodeproj` | Xcode project. `project.yml` is an XcodeGen fallback that produces the same thing. |

## Build

- App: open `Cadencia.xcodeproj` in Xcode 16+ on macOS, set your team, run on a device (Bluetooth, HealthKit and speech need hardware).
- Core: `cd CadenciaCore && swift test` (Swift 6 toolchain, works on macOS and Linux).

## Connecting

1. **Intervals.icu** — Settings → Developer Settings → API key, paste into the app. OAuth becomes the primary button once an app is registered with Intervals.icu and its client id is set in `Cadencia/App/AppConfig.swift`.
2. **Apple Health** — allowed on first launch; HRV / resting HR / sleep are read, rides are written.
3. **Devices** — pre-ride screen scans for FTMS trainers (Zwift Hub, Wahoo KICKR…), heart-rate bands (Garmin HRM) and power meters, and remembers them.
4. **Coach LLM (optional)** — Settings → Coach: any OpenAI-compatible endpoint + key. Without a key, intents are interpreted on-device by `HeuristicCoach`.

## Data flow

Intervals + Health → `AppState` (JSON on disk) → `ReadinessEngine` → `DailyPrescriber` → Today. Coach notes → `CoachEngine` → `CoachIntent` → `WeekReviser` → plan → next 7 days mirrored to the Intervals calendar. Ride → `RideRecording` on disk → `UploadLedger` (pending / uncertain / confirmed / needs-reconnect) → Intervals activity (`external_id` dedup) → feedback → Intervals.
