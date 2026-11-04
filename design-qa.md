# Ride analysis: selected full-width zone rows

Date: 2026-11-02. final result: passed

## Findings and iteration

- Initial P2: default list padding made the zone rows taller than needed. Reduced each zone row's vertical insets to 8 points, removed redundant row padding, and recaptured. Post-fix captures retain readable native row sizes and single-line durations.
- No remaining actionable P0/P1/P2 issues in the inspected states. No pixel-perfect claim: the generated concept's 1123 x 1401 raster is not a valid phone-viewport specification. Native list sizing and natural scrolling intentionally replace its compressed all-in-one composition.

## Source and rendered evidence

- Selected direction: third displayed concept, `Design/ZoneExploration/2026-11-02/03-duration-ledger.png`.
- User correction: keep Intervals.icu zones for both power and heart rate. Refined source: `selected-duration-ledger.png`; exact built-in Image Gen prompt: `selected-generation-prompt.txt` in the same folder. Both original screenshot and selected concept were attached to that refinement.
- Compared refined source, implemented power capture, and implemented heart-rate capture together in one comparison input. Also inspected focused normal and largest-text captures for text wrapping and disclosures. Native screenshot dimensions: 1206 x 2622 pixels, iPhone 17 Pro 402 x 874 logical points at 3x, iOS 26.3. Captures are app screen pixels without Simulator window or device bezel.
- Post-fix normal captures: `implementation-en-dark-power.png`, `implementation-en-dark-heart-rate.png`, `implementation-en-dark-metrics.png`, `implementation-es-dark-power.png`.
- Largest accessibility size, Spanish: `implementation-es-accessibility-power.png`, `implementation-es-accessibility-ss-heart-rate.png`, `implementation-es-accessibility-heart-rate.png`, `implementation-es-accessibility-metrics.png`.
- Real completed-session navigation, shared analysis sections, and native tab bar: `integration-completed-coach-light.png`.

## Fidelity surfaces

- Typography: native SF text styles; body-size source identifiers and semibold tabular durations. Every inspected duration, including 1 h 25 min and 1 h 21 min in Spanish at accessibility XXXL, remains a complete single line. At accessibility sizes the duration moves below its label. Helper descriptions and headings wrap naturally. English unit abbreviations use Foundation's localized 1h/25m formatting; Spanish uses 1 h/25 min.
- Spacing/layout rhythm: separate flat grouped sections for power and heart rate, full-width aligned rows, thin native separators, no charts or dense legends. Metrics are collapsed by default with the original values available on expansion. Preserve existing app navigation instead of replacing it with mockup chrome.
- Colors/tokens: native primary and secondary text, black/charcoal dark surfaces and adaptive light surfaces. Stable zone colors resolved from provider ID, not array offset. SS keeps the existing purple treatment and its own clearly named row.
- Assets: no raster assets needed in the app; standard SwiftUI controls, system typography, SF Symbols and native list separators. Generated images are design references only.
- Copy/content: power zone identifiers, ordering and seconds come directly from `analysis.powerZoneTimes`; HR zone count/order comes from `analysis.hrZoneTimes` with Z1 first, as returned by Intervals. No default zone thresholds or locally recalculated time distribution. Keep zero-time entries and efforts under a minute. SS is not added to an exclusive-zone total. New supporting strings include Spanish translations.

## Interaction and validation

- Tapped Ride metrics: collapsed to expanded; all 15 values in the long-ride fixture remained present. Largest-text layout uses one metric column. The existing explanation button still reveals the explanation in the real completed-session flow.
- Followed Home > Your coach for a completed session and verified the actual shared analysis rows, using that fixture's four returned power zones and four HR zones. The focused long-ride fixture separately verifies seven power zones plus SS and six HR zones; counts are not hard-coded.
- Xcode Simulator Debug build: passed (`/tmp/cadencia-zone-layout-build.log`).
- Existing IntervalsClientTests and IntervalsDebriefTests: 19 passed, zero failures (`/tmp/cadencia-zone-layout-tests.log`).
- Foundation formatter smoke check: 0, 18, 59, 60, 3600 and 5100 seconds in en_US and es_CO; short efforts remain seconds.
- JSON string-catalog validation and git diff --check passed. No API/DTO/domain or training-calculation changes. No physical-device or live-account acceptance claim; Simulator runs used isolated fixtures.

---

# Current Home: consistent card headings and meaningful coach summary

Date: 2026-10-30. final result: passed

This update supersedes the previous card order and coach-link presentation documented below.

- All normal Home blocks now use matching, left-aligned headline text inside their grouped cards. `HomeSection` shares the heading style and 44-point minimum header height across coach, workout, event, last session, and cyclist profile. The metric and week-ahead headers use the same headline style and alignment.
- Normal content order is Training Load, Recovery Signals, Your Coach, Today's Workout, This Week, Last Session, The Week Ahead, Your Cyclist Profile. Existing conditional availability remains in effect.
- The coach link shows the current briefing headline instead of a generic invitation to view it. Completed sessions show the debrief headline. Loading, setup, and attention states remain visible when applicable.
- Pending FTP review remains available inside Today's Workout, allowing the cyclist profile to remain the final block.
- Simulator inspection verified all eight sections in order using an isolated recent-ride fixture, and confirmed every section title is inside its card. Current screenshots: `Design/HomeExploration/UnifiedHome/home-top-en.png`, `home-middle-en.png`, and `home-bottom-en.png`.
- Profile navigation and Spanish coach navigation passed. The coach headline on Home matched the headline in its detail screen. The completed-session preview showed the actual debrief headline on Home.
- Xcode simulator build and `git diff --check` passed. Build log: `/tmp/cadencia-unified-home-build.log`.
- No new localized UI keys were needed. Existing English/Spanish keys are reused; generated coach text is displayed as content.
- No training calculations or production account data changed. Physical-device verification was not repeated for this layout update.
- The updated Home preview is left open in the simulator.

---

## Previous implementation reviews (historical layouts)

# Current Home: training load first and dedicated coach details

Date: 2026-10-30. final result: passed

The latest requested layout supersedes the previous ordering and inline coach presentation documented below.

- Home now starts with Training Load (CTL / ATL / TSB), followed by Recovery Signals.
- Your Coach uses the same compact icon/title/subtitle/chevron row as Your Cyclist Profile. Its complete content is in `Cadencia/Features/Home/CoachBriefingView.swift`.
- The link reflects briefing availability, loading, setup, attention, or completed-session state. Briefing prose and coach actions are on the dedicated screen.
- Daily briefing navigation, information disclosure, and back navigation were verified in the simulator, in English and Spanish.
- The completed-session link was verified to open the full existing debrief presentation, including its scrolling content.
- Xcode simulator build passed; log: `/tmp/cadencia-coach-details-build.log`. New Spanish translations and `git diff --check` passed.
- Current screenshots: `Design/HomeExploration/CoachDetails/home-en.png`, `home-es.png`, `coach-details-en.png`, and `coach-completed-en.png`.
- Screenshot inspection confirmed the requested order, one compact coach row, readable complete briefing, and working native navigation. No actionable layout issues found in these states.
- Validation used isolated sample data on iPhone 17 Pro / iOS 26.3. This update did not repeat physical-device, dark-mode, or largest-text checks; the existing text styles and responsive metric layouts are retained.
- The Home preview is left open for review.

---

## Previous design review (historical layout)

# Home: selected coach and metric blocks

Date: 2026-10-30. final result: passed

## Visual truth and implementation

- Selected coach: `Design/HomeExploration/coach-2.png` (1047 × 1503).
- Selected metric blocks: `Design/HomeExploration/recovery-2.png` (1142 × 1377).
- Combined reference incorporating Recovery Signals first: `Design/HomeExploration/selected-home-reference.png` (1024 × 1536).
- Native implementation: `Cadencia/Features/Home/HomeView.swift`.
- Final captures: `Design/HomeExploration/Implemented/home-light-en.png` and `training-load-light-en.png` (both 1206 × 2622).
- Full-view comparison: `Design/HomeExploration/Implemented/selected-home-comparison.png`.
- Focused comparisons: `Design/HomeExploration/Implemented/selected-component-comparison.png`.

## State and normalization

iPhone 17 Pro, iOS 26.3, 402 × 874 points at 3× density. Signed Debug simulator build, isolated Home preview, October 30, 2026. Default text size, light appearance, English UI. Existing generated coach copy in the fixture remains Spanish; it has not been replaced with shorter mock text.

The references are component concepts with different raster dimensions, rather than literal device screenshots. Comparisons crop corresponding card regions, preserve aspect ratio, and normalize card widths to 450 pixels. Native status/navigation/tab chrome is excluded from the upper-Home comparison. Full-view evidence is used for ordering and hierarchy; focused evidence is used for typography, columns, spacing, and controls. A pixel-perfect full-screen equivalence is not claimed: real generated text remains longer than the mock, and the app retains native navigation and grouped-list styling.

## Findings and comparison history

1. **Fixed P1: duplicate disclosure chevrons and a compressed title.** The initial nested NavigationLinks added list accessories alongside the intended chevrons. Evidence: `home-light-en-iteration-1.png` and the first row of `iteration-comparison.png`. Metric navigation now uses explicit buttons and a navigation destination. The final component comparison shows one heading chevron, a single-line heading at default size, and three unobstructed columns.
2. **Fixed P2: largest-text heading hyphenation.** Info/navigation controls squeezed the Spanish heading into four lines. Evidence: `home-accessibility-dark-es-iteration-1.png`. At accessibility text sizes, the heading now gets the full width and its controls move beneath it; metric columns also stack vertically. Post-fix evidence: `home-accessibility-dark-es.png` and the second row of `iteration-comparison.png`.
3. **Fixed P2: metric values were too small relative to the selected design.** Values now use the scalable large-title style with tighter surrounding padding. The final recovery/training rows in `selected-component-comparison.png` show the intended dominant numerical hierarchy.

No actionable P0/P1/P2 issues remain in the reviewed states.

## Required fidelity surfaces

- **Fonts and typography:** native San Francisco text styles; semibold headline and numerical hierarchy; secondary unit labels; readable verdict captions. Values use tabular digits. Coach readiness is a quiet sentence below the headline, with no capsule. Native font metrics and original generated copy are intentional differences from the raster concept.
- **Spacing and layout:** three aligned columns and subtle vertical dividers at default sizes; vertical layout at accessibility sizes; 44-point minimum header controls. Recovery Signals is the first block, followed by the coach. Training Load remains independent farther down Home. Profile remains one compact navigation row.
- **Colors and tokens:** native grouped surfaces, primary/secondary text, system blue information actions, gray navigation chevrons, and existing semantic verdict colors. Text labels supplement color. Dark appearance was inspected.
- **Assets and image quality:** native SF Symbols for waveform, moon, heart, and controls. No raster mock is embedded in the app, and no custom artwork is required.
- **Copy and content:** existing measured values and readiness levels remain authoritative. Today-only recovery values remain distinct from training load and its planned-inclusive explanation. Missing values display dashes and neutral “no data”; measured values without a baseline have a separate neutral label. New UI strings include Spanish translations and locale-aware recovery numbers.

## Interaction and validation

- Recovery header and metric-area actions open Recovery details; back navigation works.
- Training Load opens the shared evidence screen scrolled to its training-load section.
- Information controls expand/collapse in place, including conservative guidance when recovery data is missing.
- The compact cyclist-profile link still opens the complete profile screen.
- Spanish default-size layout inspected: `home-light-es.png`.
- Largest accessibility size with Spanish and dark appearance inspected: `home-accessibility-dark-es.png`.
- Missing recovery and training-load values inspected using the offline preview fixture: `home-missing-recovery.png`; accessibility output confirmed all training values are dashes.
- Xcode simulator build passed. Build log: `/tmp/cadencia-home-selected-build.log`.
- String catalog parsed successfully, has no duplicate keys, and all new UI keys have Spanish translations.
- `git diff --check` passed.

## Limits and handoff

The work changes native UI and navigation. Core training logic is unchanged, so the core test suite was not rerun for these layout edits. Physical-device behavior and real-account generation were not exercised. The no-baseline-with-a-present-value branch compiled and was inspected in code; the runtime missing-data check exercised absent values. Screenshot comparisons, missing-data checks, and navigation checks used isolated sample data.

Simulator appearance and preferred text size were restored to light and large. The updated Home preview is left open at the top.

Final implementation checklist: selected layouts applied; Recovery Signals first; training and recovery separated; profile link preserved; localization and accessible layout checked; build and visual QA passed.
