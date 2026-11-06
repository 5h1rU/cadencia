# Cadencia

Native iOS cycling-training app that keeps **Intervals.icu as the system of record** and replaces the TrainerRoad / TrainingPeaks / ChatGPT juggling with one place that:

- reads your Intervals.icu data (athlete, wellness, activities, power curve) and Apple Health (HRV, resting HR, sleep),
- has an **AI head coach** decide every day: readiness verdict, today's ERG-ready session and the shape of the week, from 28 days of HRV / resting HR / sleep / load / RPE, the power curve, the plan and the goal event. There is no on-device fallback: the AI is the only coach, and the app range-checks every number it returns before it reaches the trainer,
- lets you plan around a goal or an event, but only keeps the coming week concrete; later weeks are intentions,
- takes voice or text notes to the coach ("Saturday I have a 120 km group ride, Thursday only 45 minutes") and revises the week,
- shows a personal cyclist profile block on Home: current rider tendencies, evidence-backed strengths, development opportunities and confidence, generated once on first opening Home with both connections and refreshed only with **Update my profile**,
- runs structured workouts on a smart trainer over Bluetooth (FTMS, ERG) with a heart-rate band and optional power meter, on a game-style HUD (live numbers, workout timeline with playhead, target band with the live marker, block countdown, what's next),
- has the coach talk during the ride: at each block start, halfway through long blocks and at the finish, the live numbers (power vs target, HR, cadence, time in zone) go to the AI and its one-line verdict comes back as a caption and spoken aloud over your music. With an OpenAI API key the voice is OpenAI TTS (`gpt-4o-mini-tts`, coach-style delivery, voice selectable in Settings); the ChatGPT plan sign-in only covers `/v1/responses`, so on that path the best installed iPhone voice speaks (`RideCommentary`, `CoachVoice`, `RideCommentator`),
- saves the ride locally, uploads it to Intervals.icu as a FIT activity exactly once, writes it to Apple Health, and pushes RPE/feel back,
- debriefs every ride without being asked: once Intervals has processed the upload, the coach gets the recording, Intervals' analysis (load, IF, NP, zone times, decoupling, efficiency factor, HR recovery, eFTP, fitness/fatigue) and the plan, and writes what the session built, how it was ridden block by block, what the body said and what comes next. It appears on the ride-complete screen and as "Last session" on Home (`RideDebrief`, `RideDebriefView`),
- estimates FTP from sustained efforts and asks before changing zones.

## Layout

| Path | What |
| --- | --- |
| `CadenciaCore/` | Swift package, no Apple-framework dependencies. Domain models, readiness, prescriber, plan builder, week reviser, coach engines (heuristic + LLM), FTP estimator, Intervals.icu client + OAuth, FIT activity encoder, upload ledger, ride engine, BLE protocol parsing (FTMS, HR, Cycling Power). Unit-tested; builds on Linux. |
| `Cadencia/` | SwiftUI app target. `App/` (state + model), `Services/` (HealthKit, CoreBluetooth, Speech, Keychain, JSON store, OAuth session), `Features/` (Home, Coach, Plan, Ride, Settings), `Support/`, `Resources/` (string catalog en → es). |
| `Config/` | `Info.plist` (usage descriptions, `cadencia://` URL scheme) and entitlements (HealthKit). |
| `Cadencia.xcodeproj` | Xcode project. `project.yml` is an XcodeGen fallback that produces the same thing. |

## Build

- App: open `Cadencia.xcodeproj` in Xcode 16+ on macOS, set your team, run on a device (Bluetooth, HealthKit and speech need hardware).
- Core: `cd CadenciaCore && swift test` (Swift 6 toolchain, works on macOS and Linux).
- App-state persistence and workout application: `python3 Scripts/test-app-state.py` (Foundation-only SwiftPM tests, no iOS test host required).

## Connecting

The cyclist profile reuses the configured coach connection. Its read-only Intervals calls are `GET /api/v1/athlete/{id}`, `GET /api/v1/athlete/{id}/activities?oldest=…&newest=…` (180 days, no activity limit), and `GET /api/v1/athlete/{id}/power-curves.json?type=Ride&curves=r.<oldest>.<newest>&now=<newest>&newest=<newest>`, following the [Intervals API schema](https://intervals.icu/api/v1/docs). The prompt and response validation live in `CadenciaCore/Sources/CadenciaCore/Coaching/CyclistProfile.swift`. Missing power data is explicit; sparse history produces a tentative profile. The report and first automatic-attempt timestamp persist in `AppState`, including failed attempts, so later visits, syncs and app launches require an explicit retry or update. A failed update preserves the last report. Generating a profile does not change FTP, readiness or the training plan.

1. **Intervals.icu** — Settings → Developer Settings → API key, paste into the app. OAuth becomes the primary button once an app is registered with Intervals.icu and its client id is set in `Cadencia/App/AppConfig.swift`.
2. **Apple Health** — allowed on first launch; HRV / resting HR / sleep are read, rides are written.
3. **Devices** — pre-ride screen scans for FTMS trainers (Zwift Hub, Wahoo KICKR…), heart-rate bands (Garmin HRM) and power meters, and remembers them.
4. **Coach LLM (required)** — Settings → Coach → **Continue with ChatGPT** runs the coach on the athlete's ChatGPT plan ([Sign in with ChatGPT](https://developers.openai.com/siwc/token-sharing-open-source/sign-in): PKCE in the system browser sheet, loopback `127.0.0.1` callback served by `ChatGPTSignIn`, tokens in the Keychain, Responses API with `store:false`). Alternatively any OpenAI-compatible endpoint + API key. Without either, Home asks you to connect a coach; nothing is decided on-device. Models are listed from the signed-in account (`GET /v1/models`), and changing one asks the coach to decide today again.

## Data flow

Intervals + Health → `AppState` (JSON on disk) → `ReadinessEngine` (measured signals: HRV, resting HR, sleep, load, legs) → `CoachBrief` → `LLMCoach.prescribe` → `DailyPrescription.parse` (intensity 0.25–1.6 FTP, ≤ 240 min per step, total within today's time, kinds/days validated) → Home + week outlook merged into the plan. The model is asked only when the brief's fingerprint changes (new wellness, ride, legs feedback, FTP, plan) or on "Ask the coach again"; any failure is shown on Home with an "Ask again" button. Coach notes → `LLMCoach.interpret` → `CoachIntent` → `WeekReviser` → plan → next 7 days mirrored to the Intervals calendar. Ride → `RideRecording` on disk → `UploadLedger` (pending / uncertain / confirmed / needs-reconnect) → Intervals activity (`external_id` dedup) → feedback → Intervals. Confirmed upload → poll `GET /activity/{id}?intervals=true` until `analyzed` → `RideDebrief.Brief` → `LLMCoach.debrief` → `RideDebrief.Report` saved on the ride file.

Calendar writes reconcile the latest calendar by Cadencia's prefixed `external_id`, then update by the server's event id. Do not rely on a supplied `uid` being returned unchanged. A failed calendar read stops the write pass, uncertain creates are reconciled before retrying, and overlapping mirror requests are serialized. Legacy unprefixed external ids are recognized only when they match a known plan session; unknown UUIDs are not ownership evidence.

Trainer activity uploads use binary `.fit` files following [Garmin's activity-file format](https://developer.garmin.com/fit/articles/cookbook/encoding_activity_files.html). They carry one-second power, heart-rate and cadence streams, trainer-reported speed and ride-relative distance when available, the recording FTP, timer start/stop events, and lap/session summaries. Recorded power targets are retained in a described FIT developer field named `target_power`; its display in Intervals has not been verified. Pauses are excluded from timer time. Missing measurements use FIT invalid values, with no invented GPS, altitude or calories. Older saved rides still decode and pending uploads use FIT with their original external ids; absent distance and pause history cannot be recovered. Every upload attempt first checks that external id and stops if the lookup fails, so an uncertain TCX upload cannot become a second FIT activity. Confirmed activities are not uploaded again. Outdoor head-unit imports continue to use the original activity already in Intervals.

Completing a ride updates the plan or standalone session and persists today's completed ride id. Home and Plan open the completed ride's details; trainer/outdoor preparation stops being offered, and a daily prescription already in flight cannot replace the completed workout. Completion is local and does not wait for an upload or AI response.

The coach's debrief is saved locally first, then appended to the activity's Notes with `POST /api/v1/activity/{id}/messages`. Every attempt first reads all Notes pages and reuses the existing Cadencia note, including after a lost POST response. Existing notes and the activity description are preserved. Pending note writes retry on refresh without another AI request, and session details read back and cache the Intervals note. OAuth grants need `CHATS:WRITE`; older grants must reconnect. API-key connections use their existing access.

Live coaching uses `RideTimeline` to align phone measurements to active workout time, accounting for pauses, ticker drift and missing samples. Post-ride debriefs follow a separate pipeline: completed workout → Intervals upload → processed Intervals analysis → coach explanation. Their measured inputs contain only Intervals results; phone-derived block averages and totals are excluded. Pending analysis is retried, never replaced by local estimates. Provider interval timing and zone exposure retain seconds for short efforts. Missing block detail stays unknown rather than becoming a failed effort. Debriefs carry an evidence revision; obsolete mixed-source reports refresh before display. A corrected report appends a clearly marked replacement assessment to Notes, reconciled by exact content to prevent duplicate correction posts while preserving the activity and earlier notes.

Home and Recovery display Intervals' dated CTL/ATL/TSB including planned load. Readiness uses the separately dated load through yesterday, so the coach's own planned workout is not counted as fatigue already accumulated. The brief includes Intervals' running cycling eFTP; a lower recent best-power curve alone does not justify an FTP decrease.

Coach generation retries transient connection failures or interrupted streams twice, after one and two seconds. Partial responses are discarded; only a completed, validated response can replace the saved session. Authentication, usage-limit and HTTP errors stay explicit, cancellation stops retries, and the interface shows a short recovery message. This retry policy applies to coach generation, not calendar writes or ride uploads.

Session-purpose validation also checks that an opener has a confirmed event the next day, brief near-threshold or above-threshold activation, mostly easy riding and full recovery. Conservative duration and exposure bounds validate the coach's output; they do not generate a fixed protocol or gate athletes by absolute HRV values. An easy-only alternative must carry its actual purpose. One invalid-purpose response gets one correction attempt before preserving the saved session. The coaching-contract revision participates in the brief fingerprint so cached decisions refresh after a policy update.

Workout edits in chat produce dated requirements and a validated workout preview. Nothing changes until the athlete chooses **Use this workout**. The preview expires when its training inputs change, completed sessions cannot be replaced, and accepted requests persist for their own day. Future requests are saved for generation using that day's recovery. Unapplied chat messages are excluded from daily decision inputs. Applying a workout preserves the scheduled session's identity and updates its existing Intervals event; a rest alternative removes its workout event through normal reconciliation.

## Outdoor training

Outdoor structured training is part of Cadencia's scope. The target head units are **Garmin Edge 8xx / 1xxx** and **Magene C6xx / C7xx**. Support must be verified per model and firmware; the family name alone is not a compatibility guarantee.

Home now offers **Indoor / Outdoor**. Indoor retains the trainer flow. Outdoor opens bike-computer preparation from Home or workout details, without requiring Bluetooth sensors or recording on the phone. The athlete chooses Garmin or Magene; that preference is persisted with backward-compatible defaults. Standalone daily sessions keep stable calendar identities across days even without a training plan.

The outdoor adapter uses outdoor FTP (falling back to the working FTP), preserves the FTP of the original prescription, clamps readiness ceilings, and never increases today's prescribed watts when changing location. Calendar delivery uses absolute watt targets so a different FTP on the device cannot raise them. Home and the outdoor block list show those prepared targets.

### Delivery

- **Garmin Edge 8xx / 1xxx:** **Send workout via Intervals.icu** reconciles the session by external id and updates the existing calendar event with `indoor: false`. In Intervals Settings, the athlete must connect Garmin and enable **Upload planned workouts** ([Intervals maintainer guidance](https://forum.intervals.icu/t/how-to-upload-plans-to-garmin-connect/5845)). Then sync Garmin Connect and check the Edge. The app reports **Saved in Intervals.icu**; it has no device-receipt acknowledgement.
- **Garmin FIT fallback:** **Prepare Garmin FIT file** saves the latest prescription, requests its official Intervals calendar export with `ext=fit&resolve=true`, selects the exact server event id, and offers the resulting file in the native share sheet ([API documentation](https://forum.intervals.icu/t/downloading-planned-workouts-from-the-api/93737)). Account, date or workout changes invalidate an in-flight result. Compatible Edge models can import workout FIT files through `Garmin/NewFiles` over USB ([manual export guidance](https://help.trainingpeaks.com/hc/en-us/articles/115001076908-Manual-Structured-Workout-Export-for-Garmin-Devices)). Sharing a file does not confirm device installation.
- **Magene C6xx / C7xx:** the app provides the exact block list and shareable workout instructions, with OnelapFit setup guidance. The [C606](https://www.magene.com/en/all-products/85-c606-gps-smart-bike-computer.html) and [C706](https://www.magene.com/en/bike-computers/255-c706-smart-gps-bike-computer.html) document workouts created in OnelapFit or imported from TrainingPeaks. A supported Cadencia/Intervals → Magene automatic workout-write interface has not been established. Cadencia does not publish to TrainingPeaks. The [OnelapFit FAQ](https://www.onelap.com/faq.html) says FIT uploading is unsupported and describes some workouts being classified as indoor when route data is absent. The Magene screen explicitly requires manual setup and firmware verification; it never claims an automatic transfer succeeded.

Calendar mirroring and explicit outdoor sends share a serialized write lock. A failed calendar read stops the write; an uncertain create is reconciled before retrying. A delivery receipt belongs to a specific date and prescription revision, and an old FIT share is hidden after targets change. Current mode and session identities survive coach regeneration.

### Returning rides

Before a ride, use **Plan a route** on Home or **Add a route (optional)** on a cycling session to attach a GPX to a date. Maps, elevation, categorized climbs and the landscape explorer are shared with event preparation. Original GPX copies stay locally under `routes/`; exporting a selected course preserves its source coordinates, rather than the simplified map preview. Navigation GPX sharing is separate from structured workout delivery and does not confirm head-unit receipt. Attached courses survive coach revisions independently of the prescription, and course geometry is omitted from coaching briefs.

After recording on the head unit, bring the activity into Intervals.icu. Garmin can use its Intervals activity connection; Magene riders can export their recorded FIT from OnelapFit and import it into Intervals. Refresh imports outdoor cycling activities into **Ride history**, including free rides with no planned course. Only an explicit `paired_event_id` match completes a known outdoor session; a similar title or date is insufficient.

Imported head-unit rides get stable local ids and are never enqueued for upload or written to Health again. Opening an outdoor ride automatically downloads its recorded GPX through the official Intervals activity export, analyzes climbs, and caches the result in that ride's JSON. Provider restrictions or missing GPS show retry and manual recorded-GPX import controls; a planned course never substitutes for actual GPS. Explicitly paired sessions enter the existing automatic coach-debrief flow; free rides can request a debrief on demand. The coach uses Intervals analysis and actual activity totals; missing phone samples do not become fabricated block-compliance measurements.

Core tests cover target ceilings, FTP changes, revision invalidation, older JSON, explicit activity pairing, account-specific stable import ids, outdoor calendar writes, exact-event FIT selection, malformed exports and external-ride debrief inputs. Hardware delivery, provider account setup and Magene outdoor behavior remain unverified on physical devices.

## License

Copyright (C) 2026 Felipe Janer

Cadencia is free software: you can redistribute it and/or modify it under the terms of the GNU Affero General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version. It is distributed in the hope that it will be useful, but without any warranty; see the [LICENSE](LICENSE) file for details.
