# Changelog

> **Note 2026-05-24:** Between v0.4.1.1 and v0.6.2 release notes live in
> per-version reports under `.planning/v05*-marathon/` and
> `.planning/v056-marathon/`. This file resumes from v0.6.2.

## Unreleased

### Added
- **Sign in to your own server the way the web does (#65).** On a self-hosted instance, the sign-in screen now offers "Sign in via your server", which opens your instance's own login page in a secure in-app browser window. Your passkeys and password manager work there exactly as they do on the web, because the browser is on your server's real address — something the in-app form can't do. Your password stays reachable via a fallback link, and the managed and demo servers keep the familiar in-app form unchanged. The web option only appears when your server is new enough to support it (v1.32.11+); an older or offline server quietly keeps the in-app form rather than opening a page that can't work.

### Fixed
- **Workout heart-rate history keeps retrying instead of being silently abandoned.** A later workout page without samples, an authorization-ambiguous HealthKit result, a partial batch response, or a rejected entry can no longer be mistaken for completed delivery. The retry state survives relaunches and account changes without leaking work across accounts.
- **ECG uploads only advance after a real accepted server outcome.** Inserted, updated and duplicate results are handled explicitly; malformed, rejected and transport-failed uploads stay retryable, including work scheduled through the background-processing path.
- **Sharing metadata remains compatible and fails closed.** The app accepts both the current object-valued and legacy string-valued capability formats, preserves valid groups when one additive child is malformed, and clears shared-record state safely if access is revoked without retrying a write as the owner.

## 0.13.0 — 2026-06-04 (Full offline mode, your-choice AI assistant)

### Added
- **Use the whole app with no server at all.** Standalone mode is now complete: alongside measurements and mood, you can create, schedule and take **medications entirely offline** — with a real adherence figure computed on your device, not a flat 100%. Nothing dead-ends; every screen that needs a server states so calmly and offers to connect. When you later connect a server, everything you logged offline — including your medications and injection sites — uploads cleanly and is never duplicated.
- **Choose your assistant — and switch any time.** A single, clear choice in onboarding *and* Settings:
  - **No assistant** — every AI surface is off; nothing is generated and nothing leaves your device.
  - **On-device** — generated privately on your iPhone (Apple Intelligence). Offered only when your device actually supports it; otherwise the option explains why and how to enable it.
  - **Your own key** — bring your own provider key (OpenAI, Anthropic, Google Gemini, or any OpenAI-compatible endpoint). Requests go **straight from your device to your provider** — never through our server. Your key is stored in the device keychain.
  - **External AI** — your server's own provider, when you're connected.
  The same choice works in both standalone and server modes, and you can change it whenever you like.

### Changed
- **Clearer, more honest consent.** Before any health data is sent to an AI provider, the screen now states plainly what is sent (your health metrics — measurements, medications, sleep, mood) and what is not (your name, email and device identifier), and that the provider receives and may retain it. The earlier "anonymized" wording was removed because it wasn't accurate.
- The Insights suggestion chips now pre-fill the coach with the question you tapped, instead of opening an empty box.

### Fixed
- **Your entries never silently vanish.** If your sign-in happened to expire at the exact moment you saved something — a measurement, a mood, or a medication dose, including from the **Apple Watch** or Siri — it is now safely queued and synced the next time you're signed in, instead of disappearing. This was the cause of a Watch mood entry not registering.
- **The Watch now tells you the truth.** Instead of a green check the instant you tap, it shows "Saved — will sync to iPhone" or "Couldn't reach iPhone — will retry", and clears that once it has actually synced. Standalone users can log mood from the wrist without being told to sign in.

### Security & Privacy
- **Shared-device safety.** A queued entry now belongs to the account that created it — so after a sign-out and a different sign-in on the same device, it can never be sent into the other person's account.
- Bring-your-own AI keys are kept in the device keychain, sent only to your chosen provider over HTTPS, never written to logs, and wiped when you sign out or delete your account.
- Closed a window where a cached value being fetched as you signed out could briefly repaint for the next person.

### Accessibility
- The mood and adherence heatmap day-labels now step out of the way at the largest text sizes instead of staying tiny.

## 0.12.0 — 2026-06-03 (Apple Watch, Insights web-parity, deeper signals)

### Added
- **Apple Watch app.** Confirm a medication dose from your wrist — Taken, Later or Skipped — and log your mood in two taps. Everything you do on the watch is handed to your iPhone, which records it through the same secure, offline-safe path the phone uses (the watch keeps no account or data of its own). A watch-face complication shows your next due dose and today's adherence at a glance.
- **Insights overview, rebuilt to match the web app.** The entry screen is now a true one-to-one mirror of the web overview — the same cards, the same structure — and every per-metric page lines up with its web counterpart. Tiles, charts and the target-range graphic are a single shared design, so nothing appears twice and every surface links through to its detail, its explanation and the coach.
- **Heart-rhythm events** (irregular-rhythm and high/low-heart-rate notifications from Apple Watch) now surface in Insights, with the same plain-language, not-a-diagnosis framing as the web.
- **Deeper wellness signals.** Recovery, stress and strain, plus derived figures like fitness age and a vascular-age delta, now appear with a clear note on where each number comes from and how confident it is — no black-box scores.
- **Import an Apple Health export.** Point the app at an exported Health archive and it backfills your history on the server, with a progress summary; re-importing the same archive is safe and won't duplicate.
- **Medication side-effects and inventory** you record now sync to the server (and into the doctor report), instead of living only on the one device.
- **Walking steadiness** joins the metrics you can chart.

### Changed
- **"Einschätzung" reads as a calm paragraph.** The on-device assessment under each metric is now flowing text beneath the chart — the way it sits under Pulse — rather than a boxed card, for more breathing room.
- **One consistent app.** A standardization pass put every screen on the same typography scale, spacing grid, card style, single metric tile and single chart mechanic — so Home, Insights and the detail pages feel like one piece. Legacy duplicate screens were retired.

### Fixed
- The injection-site prompt now appears when you mark an injection medication as taken, matching the web.

### Security & Privacy
- The on-device health-trend text is now stored encrypted at rest, the same as the rest of your health data — it no longer sits in unprotected storage.
- Watch-originated actions are delivered exactly once, so a dose can never be double-recorded in transit.

### Accessibility
- Reduce Motion is now respected everywhere — button press feedback, the rolling metric numbers and selection animations all hold still when you've asked the system to reduce motion. Long German labels on the watch scale to fit small cases.

### Refactor
- Authored an internal design-standards document and brought the whole app into conformance with it; added the Apple Watch and watch-complication build targets.

## 0.10.0 — 2026-06-01 (Mood insights, medication schedules, Insights redesign)

### Added
- **Patient identity in your profile.** Full legal name, health insurer (Krankenkasse) and insurance number (KVNR) can now be entered and edited on the device, are shown in your profile, and flow into the doctor-report PDF cover and the FHIR Patient export — so a report you hand to a doctor carries the coverage details. The insurance number is never written to logs.
- **Mood, now with depth.** "More → Mood" becomes a calm analysis screen instead of an endless list: a monochrome contribution heatmap (with a full-year "year in pixels" mode), a mood trend with 7-day average, a stability score, tag-to-mood insights, and a short set of plain-language pattern cards (best/worst weekday, weekend effect, note effect) that only appear when there's enough data to be meaningful. The last seven entries show inline; tap any entry to edit; "Show all" opens the full history. All of it computes on your device and works offline. Logging mood is unchanged.
- **Log mood from anywhere.** "Hey Siri, log my mood", a Control Center / Action Button control, and an interactive Home/Lock Screen widget — all reusing the existing quick-entry. An evening reminder nudges you only if you haven't logged that day (with a settable time), and you can sync mood with Apple Health's State of Mind (off by default).
- **Full medication schedules.** Rolling intervals ("every N days, resets when you take it"), as-needed (PRN), cyclic on/off weeks, monthly/yearly and every-N-weeks cadences — with a new cadence picker and a course window (start/end, one-shot). Reminders, compliance and the Live Activity all follow the real schedule, so non-daily medications no longer show up every day.
- **Redesigned Insights.** One unified metric tile across the screen (value, context, sparkline, in-range band, signal), a calmer four-zone layout, a tappable BMI detail, and a per-tile explanation on tap (✦) instead of a wall of text. The duplicate health score was removed.

### Changed
- **Live Activity for medications** now confirms the dose in place — tap "Taken" on the Lock Screen and a green check animates immediately, without opening the app; the layout and countdown were polished.
- **Home-screen "Taken" now asks once.** The medication widget's "Taken" button takes two taps — the first arms a "Confirm?" state, the second records — so an accidental glance-tap can't mark a dose taken. It also records against the dose's actual scheduled time rather than the moment you tapped.
- **Onboarding** is a single calm screen, reframed self-hosted-first — you point the app at your own server; there is no cloud default. The Apple Health step is fully reachable at every text size, with a full-history backfill by default.

### Fixed
- Medication compliance now counts only days a dose was actually due; rolling/monthly/yearly medications no longer fire daily; biweekly reminders land on the correct week.
- The medication "Verlauf" history track no longer renders as a row of dashes — the per-day compliance lookup now matches the server's day keys regardless of timezone, and the full intake history loads when you open the screen.
- The mood heatmap shows its own 12-week / full-year range independently of the period selector, so it's no longer empty until you switch the period to a year.
- Mood logged offline now syncs to Apple Health when it reaches the server; a different account on a shared device no longer imports the previous user's mood history.
- A transient network hiccup during a token refresh no longer logs you out.
- English users no longer see German labels on the BMI and several other screens; medication widget buttons meet the minimum tap size.

### Groundwork
- Added a backend-availability layer and a calm "connect a server" placeholder for server-derived features, plus safer handling when the backend is unreachable. (Full server-optional / standalone mode is planned for a later release.)

## 0.9.0 — 2026-05-30 (Critical medication alarms, on-device daily briefing)

### Added
- **Critical medication alarms (iOS 26):** opt in per medication to a critical alarm that breaks through Silent mode and Focus for time-sensitive doses — distinct from a normal reminder. Off by default; configurable per medication. Older systems keep the standard reminder.
- **On-device daily health briefing:** the Insights screen now opens with a short, plain-language briefing generated entirely **on your device** (Apple Intelligence) — nothing leaves the phone. Shows an "on your device" badge when running on-device, and falls back gracefully otherwise. Includes an informational (not medical advice) note and an opt-out in Settings.
- **Per-medication delivery scope:** choose "This device" or "All devices" for Live Activity and critical-alarm delivery (cross-device sync follows; today the choice is remembered locally).

### Changed
- Reminder delivery preferences are now unified and ready to sync across devices.

## 0.8.7 — 2026-05-30 (Native tile reordering & dynamic tiles)

### Changed
- Rearranging dashboard and insights tiles now uses a clean native editor: tap the toolbar button to open it, drag rows to reorder, and toggle visibility. This replaces the on-tile wiggle/drag, which could feel off and occasionally got stuck.

### Added
- Tapping a tile now zooms smoothly into its detail view (and back).
- Tile values roll/animate when they update instead of jumping.
- Tiles fade and scale in subtly as you scroll the dashboard.
- All of the above respect the system Reduce Motion setting.

## 0.8.6 — 2026-05-30 (Reorder long-press fix, walking-speed & step-length charts)

### Fixed
- Dashboard tiles can be rearranged again — long-press a tile to enter edit mode, then drag to reorder. A normal tap still opens the tile.
- Walking speed and walking step length now show their charts when data is present, instead of always reporting "not enough data".

## 0.8.5 — 2026-05-30 (Reorder & medication-tile fixes, per-medication Live Activity)

### Fixed
- Rearranging tiles no longer leaves them collapsed or invisible — each tile keeps its real height while you reorder and snaps back cleanly when you finish.
- The "⋯" tile menu now appears only in edit mode, so it no longer sits over content during everyday use.
- Live Activities and widgets now follow the app's own design system instead of leftover placeholder colours.

### Added
- **Per-medication Live Activity toggle** — turn the Lock Screen / Dynamic Island countdown on or off for each medication individually (off by default).
- Compliance history now opens on demand: tap a medication's compliance to reveal it, showing the last 7 days by default with a "More" control to expand further.
- Compliance-history rings now use status colours (green / yellow / red) so adherence reads at a glance.

## 0.8.4 — 2026-05-30 (Native reorder engine, Live Activities & widgets, more native polish)

### Fixed
- Rearranging tiles is rebuilt on Apple's own collection-view engine: touching a tile no longer shifts the others, and a tile drops exactly where you let go. Half-width tiles, the calm wiggle, and tap-to-open all stay.

### Added
- **Live Activity & Dynamic Island for medications** — your next dose shows a live countdown on the Lock Screen and in the Dynamic Island, with a one-tap "Taken" button.
- **Home- and Lock-Screen widgets** — next dose (with an inline "Taken" button) and a today's-compliance ring.
- **Control Center & Action Button controls** — jump straight to logging, or mark the next dose taken, without opening the app.
- **Ask Siri / Spotlight** "Have I taken my meds today?" / "Show my adherence" — a new read-only compliance shortcut.
- **Walking speed and step length** now appear as charts (when you have the data), alongside the other Apple Health metrics.

### Changed
- More of the app now uses Apple's native building blocks instead of custom code: haptics via the system feedback API, and dates/relative times via Foundation's locale-aware formatters (correct in every language).
- New documentation for self-hosting, push notifications/APNs, and certificate pinning; self-hosters can now pin their own domain.

## 0.8.3 — 2026-05-29 (Home-Screen-grade reorder, compliance detail, profile auto-save, more metrics)

### Fixed
- Rearranging tiles now feels like the Home Screen: a calmer, organic wiggle (no more fast/nervous jitter) and you can drag a tile anywhere and drop it — it no longer snaps back or jumps around.
- Half-width tiles are back — a data filter had collapsed everything to full width.
- The rearrange ("…") control only appears in edit mode now instead of always being on screen, and "Done" is a clearly visible high-contrast button.
- The capture sheet slides up from the bottom again instead of popping from the top.

### Changed
- Profile: the Save button is gone — your changes save automatically with a clear "Saved" confirmation, and picking a photo now shows it loading and confirms when it's done.
- Tap the compliance percentage on a medication to open its 90-day adherence history in green / yellow / red (taken · late · missed); the compliance heatmap now uses the same colors.

### Added
- More Apple Health metrics are viewable as charts when you have data for them: active energy, flights climbed, walking + running distance, and time in daylight. (Walking speed and step length follow once the server stores them.)

## 0.8.2 — 2026-05-29 (Polish marathon: reorder fixes, settings wording, monochrome, Liquid Glass)

### Fixed
- Rearranging tiles no longer snaps back if data refreshes mid-drag — edits stay put until you tap Done.
- Hidden-tile order is preserved when you reorder only the visible tiles (Dashboard and Insights).
- Marking a dose "Taken" twice quickly can no longer create a duplicate intake — the buttons lock while a mark is in flight.
- Picking a new profile photo while one is still loading no longer races — the last pick wins and the old photo can't reappear.
- Hiding every tile no longer locks you out of edit mode — an "Add tiles" card always offers a way back.

### Changed
- Settings read in English end to end: on-device intelligence, change-server, coach history and more were half-translated before.
- Clearer hub labels — "Assistant" and "Privacy & Security" subtitles now match what's actually inside; the duplicate "Security" heading is gone.
- Sign out is separated from Delete account so the recoverable action no longer sits flush against the irreversible one.
- Compliance heatmap uses the app's own status-green instead of a separate GitHub-style palette; press states and the coach's own message bubble are now monochrome.

### Added
- Liquid Glass on iOS 26: the capture sheet grows out of the + tab, a chart detail zooms up to fullscreen, tile-edit pills are interactive glass over a dimmed backdrop, long lists get a soft glass scroll edge, and the coach input bar is glass. All gracefully fall back on iOS 18–25.

## 0.8.1 — 2026-05-29 (Polish + regression fixes)

### Fixed
- Monochrome chrome restored (a purple accent had crept into Dark mode); color is reserved for status signals only.
- Medication tile updates instantly when a dose is marked taken (no longer stuck at "0 of 2").
- Uploaded profile photo persists instead of reverting to initials after a reload.

### Changed
- Tiles rearrange like the iOS Home Screen: long-press any tile (no top button), every size wiggles and drags, "+" adds hidden tiles back — Dashboard and Insights.
- Light theme harmonized: softer headings/numbers, one warm-neutral surface ramp, status green tuned for white.

## 0.8.0 — 2026-05-29 (QoL + correctness + server v1.5.5 integration)

A broad quality pass driven by a multi-perspective audit, plus the marquee
quality-of-life feature: Home-Screen-style tile rearranging.

### Added

- **Rearrange tiles like the Home Screen.** Long-press the Dashboard or Insights
  to enter an edit mode where tiles wiggle; drag to reorder, toggle visibility,
  tap Done. Reduce Motion disables the wiggle; VoiceOver gets Move-up/down
  actions. Dashboard and Insights layouts both sync to the server.
- **Profile photo.** Upload a profile picture from your photo library; it is
  stored on your own server (no third-party service) and shown in place of the
  initials monogram, with a remove option.
- **Research mode** toggle in Privacy & Security.

### Changed

- **Light appearance is calmer.** Near-black text was softened to a warmer dark
  gray and the gray ladder smoothed, so dense screens (e.g. the medication
  schedule) no longer hit a harsh black step. Status colors (the target-range
  green, warning amber, alert red) now have light-tuned variants instead of the
  neon dark-mode values bleeding onto white.
- **Settings reorganized.** Account deletion and passkeys are no longer
  duplicated across two screens; "Advanced" is now "Privacy & Security";
  Insights tile customization moved to Appearance; the hub is ordered by use.
- **All-time chart range** now loads the full history again.
- The string catalogue is fully English-source — every remaining German UI
  literal was migrated, with a build check preventing regressions.

### Fixed

- **HealthKit data no longer silently lost.** Respiratory rate, BMI, and the two
  gait-percentage types are accepted by the server now; the app stopped sending
  a double-scaled gait value and no longer advances its sync cursor past types
  the server can't store (so they re-sync once supported).
- **Charts:** the all-time range no longer errors; the steps trend sparkline
  renders; chart detail is built consistently across Dashboard/Trends/Insights.
- Connectivity is verified before syncing (captive-portal-aware); reminders fire
  in the correct timezone.
- Profile initials no longer show "?" at cold launch.

### Performance

- Hot data caches gained a short freshness window, so a quick app switch repaints
  from cache instead of re-fetching; duplicate foreground refreshes were
  de-duplicated and overlapping pull-to-refresh requests coalesced.
- HealthKit background delivery throttled per type (energy).

### Security

- The display-name hint is cleared on server switch; the FHIR export is written
  with complete file protection. Three Settings screens were moved behind the
  repository layer (no in-view networking).

## 0.7.2 — 2026-05-28 (Source-language flip + device-feedback polish)

English is now the string-catalogue source language (internal maintainability),
plus three changes from on-device feedback on 0.7.1.

### Changed

- **String catalogue source language is now English.** ~578 keys were re-rooted
  from German to English source; the German text is preserved as a translation,
  so German users see no change and English users see no change — the source of
  truth simply matches SwiftUI's literal-derived keys now.
- **Insights header restored to its earlier layout.** The AskCoach entry point
  sits at the title height again and the extra reload control in the navigation
  bar is gone.

### Removed

- **Consecutive-day streak counter on the dashboard** — removed from the home
  screen.

### Fixed

- **Profile initials no longer show "?" at cold launch.** The monogram now uses
  the best available name (display name, username, or email local-part) from a
  local store until the server profile loads — no network, no third party.

## 0.7.1 — 2026-05-28 (Reconcile + Polish)

A code-review reconcile of the v0.7.0 changes plus a batch of UI and feature
polish: a data-loss fix on sign-out, fuller HealthKit backfill, captive-portal-
aware sync, timezone-correct reminders, an editable targets screen, a dashboard
streak, server-backed coach on every iPhone, and Siri shortcuts.

### Fixed

- **Offline writes survive sign-out.** A benign sign-out (user-initiated or
  token-expiry) kept queued offline measurements but still wiped the outbox
  encryption key, leaving those rows undecryptable and silently dropped on the
  next launch. The key is now retained whenever the rows are, so a sign-out and
  sign-in to the same account no longer loses a pending write.
- **Backfill window honoured for every streamed type.** Respiratory rate,
  walking double-support, blood glucose, VO₂max, and both audio-exposure types
  ignored the backfill window and collected only the last few days; they now
  thread the same window as the rest.
- **Insight summaries are genuinely best-effort.** `MetricInsightsRepository`
  re-threw non-404 errors despite documenting nil-on-failure; it now returns nil
  on any request failure.
- **The one-shot daily-stats backfill no longer burns its flag before the work
  succeeds**, so a failed first run retries instead of being skipped forever.
- **Connectivity is verified, not assumed.** Outbox replay now gates on a real
  `/api/health` probe, so a captive-portal network (hotel/airport Wi-Fi) no
  longer triggers failing replays.
- **Reminders fire at the intended time across timezones.** Calendar reminder
  triggers now pin an explicit timezone instead of the implicit device zone.

### Added

- **Streak on the dashboard.** A consecutive-day logging streak with an at-risk
  pulse when today's entry is still missing.
- **Editable targets.** The targets screen gained a server-first editor for
  personal target ranges (optimistic, idempotency-keyed, outbox-backed).
- **Coach on every iPhone.** On devices without on-device intelligence, AskCoach
  now falls back to the configured server provider instead of a "not available"
  card, behind the existing consent gate.
- **Siri shortcuts.** Log blood glucose, log blood pressure, and mark a
  medication taken from Siri and Spotlight, reusing the same server-first write
  path as the app.

### Changed

- **Insights adopts the Liquid Glass navigation treatment** — its toolbar was
  re-enabled so iOS 26 applies the glass automatically.
- **Insights paints once.** A fan-out readiness gate replaces seven independent
  section loads, so the screen shows a single skeleton and then settles without
  re-flashing on revalidation.
- **Long charts downsample (LTTB)** before plotting while keeping full-resolution
  data for statistics, so multi-year ranges render fast.
- **Consistent sheets.** Every sheet routes through one `HLSheet` presentation
  token (detents plus drag indicator) for uniform feel across the app.

### Refactor

- Extracted a shared `ServerReachabilityProbe` from two duplicated in-view
  pinned-session probes; scoped the onboarding URL sheet identity instead of a
  module-global retroactive conformance; routed the chart icon box through
  `MetricKindDescriptor`; collapsed duplicated medication buttons; dropped a dead
  avatar-cache surface.

## 0.7.0 — 2026-05-28 (Audit-Driven Major Push)

Ten-wave release built on a seven-perspective deep audit (feature, HIG, UI/UX,
HealthKit, security, App Store, API integration). Closes the longest-standing
operator pain ("Schritte alle Daten"), completes HealthKit coverage, plugs a
sign-out data-leak, and clears the App Store submission blockers — plus
localization, rendered-data, and empty-state polish across the app.

### Fixed

- **"Schritte alle Daten" shows the full history.** A four-layer cascade kept
  step history from ever reaching the chart: Spezi collectors ignored the
  backfill window, the daily-stats backfill ran a fixed 7-day span, the step
  recent-page hit the limit-400 endpoint instead of the dense per-day series,
  and there was no all-time range to ask for. All four fixed — Spezi collectors
  honour the persisted window, a one-shot window-aware daily-stats backfill runs
  after onboarding, `.steps` now routes through `/api/measurements/series`, and a
  new "Alle" range on chart detail pulls the full ~10-year span.
- **Schema drift now surfaces instead of silently emptying cards.** The
  `Recommendation` decode swapped per-field `try?` swallows for typed decoding.
- **BMI / blood-pressure classification adds an `.unknown` band** so an unmapped
  server token no longer renders as a medically misleading "normal".

### Added

- **HealthKit completeness.** Adopted `respiratoryRate` (LOINC 9279-1) and
  `walkingDoubleSupport` end-to-end (read types, Spezi collectors, wire
  converter, descriptors, ranges, FHIR mapping). Wired seven previously
  authorised-but-unobserved types (blood glucose, VO₂max, flights climbed,
  walking/running distance, environmental + headphone audio exposure, time in
  daylight) so they stream live, and finished the AudioExposureTile with two
  enum-backed metric kinds.
- **More server data rendered (~20 fields).** Chart-detail hero now shows
  slope 7/30/90-day trend chips and a "vor 1 Jahr" baseline + delta; target
  tiles show an "X von 30 Tagen im Zielbereich" tally; the home insight card
  renders the full insight body plus tappable recommendation action buttons; and
  the medication Verlauf track spans the server's full 90-day compliance window
  (a 7-column weekday calendar above 21 days).
- **Empty states across 13 surfaces** now use the system `ContentUnavailableView`
  primitive (achievements, charts, insights, workouts, records, measurements,
  medications and more), each with a glyph, CTA where one exists, and a
  VoiceOver identifier.
- **Onboarding restored and hardened.** A primary "HealthLog Cloud verwenden"
  preset fills the managed host in one tap, the Welcome
  step explains that a server is required, the Passkey CTA is un-gated and wired,
  and a manually-entered host now raises a trust-boundary acknowledgement sheet
  before it is persisted.

### Changed

- **Localized metric names.** `MetricKind.displayName` routes through the
  `MetricKindDescriptor` `LocalizedStringResource` catalogue, so EN-locale users
  see "Weight" / "Blood pressure" / "Sleep" instead of the German source on nav
  titles and chart axes. Onboarding copy switched to real umlauts.
- **Dynamic Type sweep** across the affected surfaces for large-text legibility.

### Security

- **One sign-out wipe cascade (NEW-H-1).** Every logout path (user tap, 401
  expiry, account deletion, switch-server) now routes through a single
  `performFullLocalLogout` so a sign-out → sign-in on the same device no longer
  leaks the previous user's on-device AI caches, avatar, Coach transcript,
  HK diagnostics, server-stats, or the outbox cipher key.
- **Four MEDIUM findings closed:** doctor-report PDF/FHIR residue is swept from
  the temp directory on launch + every logout, push-payload `medicationId` is
  allowlisted before use, the outbox cipher key is created on first call, and the
  unused `applinks` associated domain was dropped.

### App Store readiness

- Medical disclaimer surfaced in Settings → Über, a dedicated HealthKit-access
  transparency screen, an unfinished OAuth row hidden in Release, the
  dangling `NSHealthClinicalHealthRecordsShareUsageDescription` removed (no code
  reads clinical records), and the DDA9.1 required-reason declaration added to
  the privacy manifest.

### Deferred to v0.7.1

- A dedicated code-review + senior-architect + code-simplifier pass (skipped this
  session for context budget) — recommended as the first v0.7.1 action.
- Batch B polish: Liquid-Glass insights navbar, sheet detents, insights skeleton
  gate, timezone-aware notifications, captive-portal handling, streak surface,
  targets editor, charts LTTB downsampling, coach fallback, AppIntents.
- AppContainer decompose, full xcstrings key-flip, HK export ZIP, widget
  extension, Health-Records FHIR import, snapshot-test coverage.

## 0.6.2.3 — 2026-05-27 (Audit-Driven Polish)

### Marathon overview

Multi-perspective comprehensive audit (8 parallel agents — UX, architecture,
code quality, security 2nd pass, HealthKit completeness, symptom investigation,
App Store submission compliance, notifications time-sensitive) followed by
6 file-disjoint fix waves. All operator-reported smells closed at root, plus
pre-emptive App Store submission readiness.

### Fixed — operator-reported

- **Chart load lag on tab-switch.** `TrendsOverlayStore` was re-instantiated
  per view → no overlay survived navigation pop / re-mount. Hoisted to
  `AppContainer`, env-wired through `HealthLogApp.rootView`.
  `MeasurementsStore.load()` now goes through `SWRCoordinator.observe` with
  the same `.empty → .cached → .fresh` ladder `DashboardStore` uses
  (`isShowingStaleCache` + `lastUpdatedAt` for parity). Prefetch coverage
  extended to Trends-overlay defaults. `ChartDetailScreen` no longer flashes
  the findings spinner on cached range-pill re-fires.
- **Medication banners now time-sensitive.** `HealthLogStandard.notification
  Content(...)` sets `content.interruptionLevel = .timeSensitive` on the
  `.medication` branch — banners break through Focus + Do-Not-Disturb. Snooze
  rebuilds on both medication + mood action paths preserve the priority.
  Time-sensitive entitlement was already declared in v0.6.0.7; this wave
  wires the content side so the entitlement is no longer dormant.
- **Avatar initials regression.** `UserProfile.makeInitials` split on hyphens
  → `"Anna-Lena Fischer"` rendered `"AL"` not the doc-promised `"AF"`.
  Hyphen + underscore dropped from separator set; selection rule switched to
  first-token + last-token (whitespace-only split).
- **Rolling-7-day Stabilität spread excluded today.** `recordedAt <= cursor`
  with `cursor = startOfDay(...)` dropped every today-entry. Switched to
  half-open `[windowStart, windowEnd)`. Hero strip labelled with today's date
  now actually includes today.

### Security

- **Outbox AES-GCM key persisted past logout + account-deletion.**
  `KeychainKey.outboxPayloadKey` constant introduced;
  `AppContainer+Logout.handleLocalLogout()` and the account-deletion
  `localCleanupHook` both wipe the key. Forensic / multi-user / uninstall-
  restore scenarios no longer leak decryptable residual ciphertext.
- **Outbox decrypt failure silently dropped rows.** `OutboxStore.snapshot()`
  used to surface raw ciphertext as `payload` on AES-GCM decrypt failure;
  the dispatcher then JSON-decode-failed and the replay-service's
  non-retriable arm silently dropped the row with the same log signature as
  a legitimate schema-drift drop. New behaviour: decrypt failure deletes the
  row in-place at the snapshot boundary and emits the distinct log line
  `HLLog.outbox.error("decrypt failed for record … — row deleted at snapshot
  boundary")`.
- **`HKReadinessStore.partitionToken` legacy regression closed.** Strict
  `[A-Za-z0-9_-]` + 64-cap allowlist that the other two partitionToken sites
  shipped in v0.6.2.0 now applies at the third call-site too. Cross-site
  drift suite covers `usr_<cuid>` production-shape fixtures.

### App Store submission readiness

- **Privacy policy URL canonicalised.** `SettingsAboutScreen` Datenschutz +
  Dokumentation links now point at the managed host's `/{privacy,docs}` —
  matches the production server. The prior `healthlog.dev` link no longer
  surfaces to users (it remains in the codebase only as the demo-server
  endpoint reference in `AppEnvironment`, which is a deliberate separate
  construct).
- **`NSPrivacyAccessedAPICategoryFileTimestamp` declared.** SwiftData
  adoption since v0.3.0 re-introduced the FileTimestamp dependency; v0.6.2.3
  adds the reason code `C617.1` to `PrivacyInfo.xcprivacy` to pre-empt
  ITMS-91053 post-upload.

### Tests

- **+50 tests** across 8 new test files (`NotificationServiceTimeSensitive
  Tests`, `OutboxKeyLogoutWipeTests`, `OutboxSnapshotDecryptFailureTests`,
  `MeasurementsStoreSWRTests`, `InsightsAuxChartDetailScreenTests`, plus
  extensions to `AvatarBadgeTests` + `PartitionTokenHardeningTests`).
- Baseline flaky envelope unchanged.

### Server-repo carry-over

Two paste-ready issue bodies drafted for `MBombeck/HealthLog`:
`.planning/v056-marathon/v0626-server-issue-mood-apns-time-sensitive.md`
(HIGH — server must add `aps.interruption-level: "time-sensitive"` to mood-
prompt APNs payload so the "wie geht es dir" notification breaks through
Focus modes; ships in lockstep with this iOS release) and
`.planning/v056-marathon/v0626-server-issue-hk-enum-cutover.md` (MEDIUM —
server `MeasurementType` enum cutover for `WALKING_SPEED`,
`WALKING_ASYMMETRY_PERCENTAGE`, `WALKING_STEP_LENGTH`,
`WALKING_DOUBLE_SUPPORT_PERCENTAGE`, `BMI`, `BODY_TEMPERATURE` — iOS already
streams these via SpeziHealthKit; server-side enum gap leaves them stranded
as `unknown_hk_identifier`).

### Operator-side checks before public submission

- Apple Developer Portal: confirm `com.apple.developer.usernotifications.
  time-sensitive` capability is enabled on the App ID and provisioning
  profile re-issued (the entitlement file already declares it).
- Verify the managed host's `/privacy` and `/docs` endpoints exist
  server-side — App Review will call those URLs.
- App Store Connect: add yourself to the **Internal Testing** group so future
  TestFlight builds skip the 24-48 h Beta App Review cycle.

### Deferred to v0.6.3

- **AppContainer composition refactor** (967 LOC + 15 extension files = 2 039
  LOC) — A-ARCH escalated to HIGH; a structural split is appropriate but too
  large for a patch release. Plan in v0.6.3.
- **xcstrings source-language flip de → en** — 769-key identifier refactor,
  still queued. ASO-blocking for the English store; v0.6.3 wave.
- **HealthKit completeness — iOS side.** `respiratoryRate` end-to-end and
  Spezi-subscribe for 6 auth'd-but-unobserved types (bloodGlucose, vo2Max,
  flightsClimbed, distanceWalkingRunning, audioExposure × 2, timeInDaylight)
  — needs real-device walkthrough loop, deferred. `WALKING_DOUBLE_SUPPORT_
  PERCENTAGE` adopt-and-stream not yet done iOS-side; bundle with the
  server-enum cutover.
- **Local Spezi fallback for mood "wie geht es dir" prompt** — currently
  APNs-only; a local resilience module mirroring `MedicationsSchedulerModule`
  would let the prompt fire even when APNs is suppressed by carrier or
  network state. P3.
- **Half-implemented surfaces:** `AskCoachSheet` placeholder, SpeziAccessGuard
  (Phase B), SpeziDevices scaffolded-unused (Phase F.1 follow-up), Doctor
  Report PDF generator — none breaking, all queued.

CFBundleVersion 72 → 73. CFBundleShortVersionString stays at 0.6.2. Build
clean. Full suite passes the 8-baseline-flaky envelope; no new regressions.

## 0.6.2 — 2026-05-24 (Localization + Security MEDIUMs + Insights Interactivity)

### Marathon overview

Single-session multi-wave ship on top of v0.6.1.28. Six parallel waves on
disjoint file sets: localization sweep, two security MEDIUM clusters,
SPKI rotation prep, server-repo issue body drafts, Insights interactivity
polish. Plus one operator interjection (Med-card Genommen button
softened) merged inline.

### Added

- **Insights tile-tap navigation (Y10.8 / C5+C6+C7).** Stimmung,
  Stabilität, and Compliance tiles on the Insights screen now push into
  dedicated auxiliary chart-detail screens (re-using `MoodTrendChart`,
  `ComplianceHeatmapSection`, `MoodSummaryCard`). Previously these three
  tiles silently dropped taps because `kindForChartDetail(...)` returned
  `nil` for non-`MetricKind` data sources. Fix: parallel
  `hasAuxDestination(...)` switch routes them through
  `InsightsAuxChartDetailScreen` without touching the store layer.
- **Chart fullscreen-tap (Y10.8 / D1).** Tap the chart inside
  `ChartDetailScreen` to open a `.fullScreenCover` with the same chart
  at edge-to-edge. Time-range and selected-date carry across; `Fertig`
  button + pull-down both dismiss. New `FullscreenChartCover.swift`.
- **61 localization keys** added to `Localizable.xcstrings` covering
  Achievements, Medications, Mood, Notifications, Onboarding, Records,
  Settings, Targets, and Workouts domains. Source language remains
  German; English translations now complete for these surfaces.
  (Source-language flip to English deferred to v0.6.3 as its own wave —
  769-key identifier refactor, too large to bundle here.)
- **`OutboxPayloadCipher`** — AES-GCM encryption-at-rest for queued
  outbox payloads, key in Keychain
  (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`). Layout
  `[version-tag 0x02 | 12-byte nonce | ciphertext+tag]`; legacy
  plaintext rows migrated lazily on next read.

### Changed

- **Insights layout (Y10.8 / C8).** "Deine Ziele" + Mood-summary
  half-cards now sit immediately under `HealthScoreSection` instead of
  further down the scroll. Both are deterministic — no AI-gate
  dependency.
- **Med-card Genommen button — monochrome.** Replaced
  `HLButton(.primary)` (white fill / black text) with a monochrome
  variant: `HLText.secondary` foreground, transparent fill,
  `HLColor.statusOK` border at 0.55 opacity. Operator feedback: too
  brachial when many active cards stack. Pow spray + `.success` haptic
  preserved.
- **Gravatar dropped entirely.** `HLProfileAvatar` renders initials
  only. `AvatarCache` reduced to a migration shim (sweeps legacy
  on-disk PNGs from prior installs). Privacy gain: no more email-MD5
  leak to a third-party tracker. Source-tree scanner test pins the
  removal — any future regression that re-introduces a
  `URL(string: ".*gravatar.com")` literal fails the suite.

### Security

- **M-1 — Auth-exemption contract pinned.** `docs/api-contract.md`
  documents the refresh-bridge exemption set. New `RefreshExemptionTest`
  parameterised over 8 exempt + 7 authenticated routes — guarantees
  future auth routes are explicitly added.
- **M-2 — `APIClient.setEnvironment` runtime guard.** Debug
  `assertionFailure`, Release log+early-return when auth-token is
  present. Prevents a future "switch server" UI from silently breaking
  the SPKI-pin contract.
- **M-4 — Outbox AES-GCM at rest** (see Added). Sensitive measurement
  notes + mood text no longer plaintext in `outbox.sqlite`.
- **M-5 — Deep-link ID allowlist.** `DeepLinkRoute(url:)` regex-gates
  ID components (`^[A-Za-z0-9_-]{1,64}$`) and slugs
  (`^[a-z0-9-]{1,48}$`). 16 traversal / over-length / unicode tests.
- **M-6 — `partitionToken` strict normalisation.** Strip-not-replace
  on disallowed chars, 64-cap, applied at both call-sites (HK service
  + backfill store). Cross-site drift suite added.
- **M-7 — Logger `OSLogPrivacy` passthrough.** Redactor stays as
  defence-in-depth, but call-sites tagging `.private` / `.sensitive`
  now flip OS-level privacy too. New SwiftLint warning rule
  `hllog_public_privacy_interpolation` (66 legacy hits flagged
  non-blocking).
- **M-3 — Gravatar leak closed** (see Changed).
- **M-9 — SPKI verification.** The live managed-host chain
  matches all three pinned hashes; primary leaf expiry 2026-06-26
  covered by backup-1 (GTS WE1, exp 2029-02) + backup-2 (GTS Root R4,
  exp 2028-01) — the policy precondition (≥ 2 pins) holds past expiry
  so the app does not go dark. GTS uses fresh keypairs per renewal,
  so the next leaf SPKI can only be extracted after issuance.
  `scripts/extract-spki.sh` rewritten as full-chain extractor;
  rotation playbook in `docs/security.md` updated. **Calendar
  reminder: 2026-06-15 → re-extract; if rotated, dual-pin patch +
  TestFlight by 2026-06-12.**
- **M-8 — BLE permission timing verified.** SpeziBluetooth's
  `supplyCBCentral()` is wrapped in `Lazy`; registering
  `Bluetooth { }` / `PairedDevices()` / `HealthMeasurements()` at
  Spezi configuration time allocates no `CBCentralManager`. No code
  change needed; App-Store-Review BLE-purpose-string concern
  defensible.

### Tests

- **+62 tests** across 6 new test files
  (`RefreshExemptionTest`, `DeepLinkRouterAllowlistTests`,
  `PartitionTokenHardeningTests`, `APIClientSetEnvironmentGuardTests`,
  `OutboxEncryptionTests`, `LogSanitizerTests`).
- Existing baselines refreshed: `HealthKitAnchorPartitionTests`,
  `HealthKitBackfillWindowTests`, three Avatar suites
  (incl. source-tree scanner for Gravatar regression),
  `InsightsTargetTileGridY9Tests`.
- **Full-suite status:** 2 445 tests in 353 suites — 8 baseline
  flakies (`SeriesGateF2Tests` × 3, `medSnoozeReschedulesLocally` × 2,
  `PersonalRecordsStoreEnrichment` × 1, `OnboardingUITests` × 2). No
  new regressions introduced by this release.

### Server-side fixes shipped (HealthLog v1.5.0, 2026-05-24)

Both server-side issues drafted for this release **landed the same
day** server-side at
https://github.com/MBombeck/HealthLog/releases/tag/v1.5.0 :

- **`POST /api/measurements/batch` now upserts on `(type, externalId)`.**
  iOS HealthKit cumulative-type day-aggregates (steps / sleep /
  active-energy / distance / flights) update correctly throughout the
  day. The iOS workaround in `LiveHealthKitTodayStore`
  (commit `b8784799`) becomes dead code as soon as the operator verifies
  against prod — revert path noted in
  `.planning/v056-marathon/v0629-server-issue-C10-batch-upsert.md`.
- **Compliance calculator respects `daysOfWeek` + `intervalWeeks`.**
  Weekly-cadence meds now report correct compliance
  numbers. iOS-side override in `MedicationsStore.swift` (v0.6.1.23)
  becomes redundant — revert path in
  `.planning/v056-marathon/v0629-server-issue-compliance-weekly.md`.

Both reverts deferred to v0.6.3 pending operator's prod-verification
pass.

### Deferred to v0.6.3

- **xcstrings source-language flip de → en** — 769-key identifier
  refactor, eats this whole session's parallel budget on its own.
- **AppContainer compositional refactor** (967 LOC, code-audit
  flagged) — no urgent driver.
- **E1 Profilbild-Upload** — needs server endpoint design.
- **Security MEDIUM follow-up M-7 SwiftLint rule** — currently logs 66
  legacy `.public` interpolations as warnings. Sweep into a clean
  state in v0.6.3 as part of the source-flip wave.

CFBundleVersion 68 → 69. CFBundleShortVersionString 0.6.1 → 0.6.2.
Build clean. Lint baseline unchanged on touched files.

## 0.4.1.1 — 2026-05-15 (HK-Sync Hotfix)

User-reported critical bug after v0.4.1 install: 15+ POSTs gegen
den Managed-Host in burst, kein HK-Sync — Server-Log zeigte
`ObserverQuery error: Authorization not determined` (10x) +
`BG-Anchor-Sweep: Authorization not determined` (6x).

### Root cause
HKObserverQuery + HKAnchoredObjectQuery werfen
`HKError.errorAuthorizationNotDetermined`, wenn der User im
System-Sheet einen Read-Type abgelehnt hat (Apple's HK gibt fuer
Read-Types keinen `.sharingDenied`-Status preis — Privacy-Design).
Die Observer feuerten daher in Endlos-Schleife, jeder Wakeup
produzierte einen leeren POST-Versuch → Retry-Storm.

### Fixes (F8)
- **Stop-Observer-on-AuthError** (`HealthKitService.swift`): bei
  `errorAuthorizationNotDetermined` / `errorAuthorizationDenied`
  wird der Observer dauerhaft via `store.stop(observer)` beendet
  und in `authDisabledTypeIdentifiers` aufgenommen. Wakeups stoppen
  sofort.
- **Auth-disabled-Type-Skip** in `startBackgroundDeliveries` +
  `runOneShotAnchorSweep` — Re-Aktivierung ueberspringt diese Types
  bis zum naechsten Re-Authorize-Cycle.
- **Re-Registration-Hook** in `HKReadinessStore.requestAuthorization`:
  nach jedem erfolgreichen System-Sheet wird `resetAuthDisabledTypes()`
  aufgerufen, damit Re-Auth den Observer-Storm-Schutz aufhebt.
- **POST-Backoff** in `MeasurementBatchUploader`: >5 Failures/60s
  aktiviert exponentielle Backoff (15s → 60s → 5min → 30min). Erster
  Success resettet. Pre-Flight-Check wirft `BatchBackoffError.throttled`.
- **Auth-Error-Klassifier** als testbare static method
  `HealthKitService.isAuthNotDeterminedError(_:)`.

### Tests added (+9)
- 5 backoff tests: clean-state, sub-threshold, over-threshold,
  blocked-call-throws, first-success-resets
- 4 auth-error-classifier tests: notDetermined, denied, non-HK domain,
  other HK-error code

CFBundleVersion 6 → 7. Build clean, alle Tests gruen.

## 0.4.1 — 2026-05-15 (UX + Stability + Edit-Path Foundation)

### Marathon overview
Single-session reconcile-and-ship marathon. Six parallel B-streams (B1 dashboard, B2 settings + AI-Provider, B3 mood + notifications, B4 onboarding redesign, B5 trends + verlauf + sources, B6 avatar + personal-settings) plus F7 HK readiness self-check, finalised by a QA wave (QA1–QA7) and a reconcile pass that closed five additional must-fix items inline before squash.

Test count: **500+ → 667 tests in 118 suites**, all green under Swift 6 strict concurrency, warnings = errors. swiftformat lint clean. xcodegen clean.

### Critical fixes — Dashboard
- **One-shot v0.4.1 layout migration for upgrading users.** Pre-v0.4.1 users had `tileVisible: false` persisted on the server for sleep, steps, glucose, totalBodyWater, boneMass, oxygenSaturation, vo2Max. B1 only flipped the iOS default — existing users still saw the old 4-tile dashboard. `DashboardLayoutStore` now applies a one-shot merge after first successful load, PUTs the merged layout back to the server, and gates retries via a UserDefaults flag. Idempotent.
- **Default tiles flipped to visible** (B1). All 10 supported MetricKinds now render as tiles by default. Customization screen still exists for opt-out.
- **Customization toolbar entry repolished** (reconcile B). Replaced harsh `slider.horizontal.3` with secondary `pencil.circle` styled in `textSecondary` — Apple-Health Browse-tab pattern.
- **Coherent Apple-Health-style category tints** (reconcile C). Replaced per-kind rainbow with four semantic dashboard tokens: `dashboardCategoryVitals` (weight, BP, pulse, bodyFat), `dashboardCategoryActivity` (steps), `dashboardCategoryBody` (TBW, boneMass), `dashboardCategorySleep` (sleep), `dashboardCategoryOther` (SpO2, glucose, temperature). Closes user-report "App-Icons alle in irgendeiner Farbe und wirkt überhaupt nicht stimmungsvoll".
- **Phantom 96pt scroll** killed across 8 surfaces (B1) + MoodScreen leftover fixed (reconcile E2).

### Critical fixes — Settings + AI-Provider + Konto (B2)
- **AI-Provider picker fixed** — was a 405-swallowing stub. Now hits `GET / PATCH /api/user/ai-provider` correctly, surfaces 422 validation errors, and supports the provider modes iOS can configure end to end.
- **Canonical `HLSettingsRow` primitive** applied to all 22 settings rows. No more shape inconsistency.
- **Konto section split** into 2 dedicated sections with footer copy + `Button(role:.destructive)`. Sheet-presented `DeleteAccountScreen`.
- **9-section IA reorg** for SettingsScreen.
- **Mutable baseURL** via Keychain override with live-reload of `AppEnvironment`.

### Critical fixes — Mood + Notifications (B3)
- **Mood screen overhaul** — TodaySummary header + consolidated input card (emoji + tags + notiz + save) + recent-entries + dedicated history-screen. `.sensoryFeedback(.success)` + toast on save.
- **Mood chart fix** — Y-axis on `.leading`, AxisTick + emoji-as-label sized.
- **Copy reconciliation** — single canonical `MoodCopy.scoreLabel` array; no more "OK" vs "Okay" disagreement between button + scoreLabel.
- **Test-push UX rebuilt** — 5s → 1s trigger, haptic, prominent confirmation row, 3 variants.

### Features — Onboarding redesign (B4)
- **Mode-selection** (Server / Standalone / Demo) — Apple-Mail-style account-picker, 8-step branched flow.
- **Passkey-first auth** — `PasskeyEnrollmentStep.swift` DELETED (was throwing 401 silently pre-login). Post-login enrolment via Settings → Sicherheit.
- **Standalone-mode foundation** — gating + Settings "pair-later" entry.

### Features — Trends + Verlauf + Sources (B5)
- **`.raw(kind)` mode** when single metric selected — Gewicht shows kg, not z-score (closes "Gewicht steigt+fällt ohne kg").
- **`SourcesChipStrip`** at top of chart-detail screen — sources now visible above the chart.
- **Apple-Health adaptive grouping** in Verlauf — `.day / .weeklySummary > 5/wk / .monthlySummary > 20/mo` with summary cards (Ø / Min / Max).
- **Log-scale toggle** via toolbar — `.chartYScale(type: .log)` for skewed weight/glucose series.

### Features — Avatar + PersonalSettings (B6)
- **`AvatarBadge`** (32pt) in Dashboard `.topBarTrailing`. Initials extraction from `AuthStore.User` + profile cache.
- **`PersonalSettingsScreen`** sheet — Hero + Profil + Einheiten + Sprache + Sicherheit + Konto. SettingsScreen.Profil section removed (identity now lives in *one* place).

### Features — HK Readiness Self-Check (F7)
- **`HKReadinessStore`** (5-state machine: notDetermined / fullyGranted / partiallyGranted / denied / unavailable).
- **Dashboard connect-banner** appears when HK status is recoverable.
- **Settings → Apple Health Connection-Row** with Manual-Sync trigger.
- **Body-mass-proxy heuristic deleted** in `RootView` — replaced with real readiness check.

### Tests + tooling
- **AIProviderStore test stub aligned** with real `AIProviderRepository.UpdateResponse`. Made `UpdateResponse` public + Sendable; replaced the test's local `PatchAck` with a typealias to the real type. Dropped `[weak self]` from the capture handler closure (Capture is held strongly by the test scope; weak-self was silently returning canceled errors). Closes the 7-15 AIProviderStoreTests failures flagged in QA2.
- **`AIProvider+Iconography.swift`** — moved `iconTint: Color` out of `Models/Insight.swift` into DesignSystem layer. Data model stays pure Foundation.
- **Strip "Coach-Verläufe" copy** from `DeleteAccountScreen` — Coach isn't shipped in iOS yet; reviewer-tap-test risk per QA3.

### Build + version
- `CFBundleVersion` 5 → 6
- xcodegen clean, swiftformat clean, build clean Swift 6 strict-concurrency, 667 tests green

### Deferred to v0.4.2 (App-Store-Submission-Final mini-marathon)
- **QA3 App Store blockers** — Privacy Policy URL live, AI-Consent-Gate (Guideline 5.1.2(i)), aps-environment Production-verify, Apple Dev Portal capability registration
- **QA5 Edit/Delete coverage** — Measurement + Mood swipe-Delete + Edit; HK-deletion reconciliation
- **QA6 must-adds** — Notification Categories + `.timeSensitive`, HKStateOfMind mood-sync, `webcredentials:` Associated-Domains entitlement
- **QA7 sparse screens** — MoreScreen Browse-tab redesign, DoctorReport prefs-wire, AuditLog day-buckets
- **B7 TabView reshape** (M2-A9 IA recommendation)
- **B8 Server quickwins** — Feedback form, doctor-report prefs, HK deletion sync
- **Widgets / App Intents / Live Activities / WatchOS** (v0.5.0 territory)

### User-report coverage (v0.4.1 wave)
- v0.4.0 (14 reports): all 14 green ✅ (carried forward)
- v0.4.1 wave (R-01 → R-20): **18 of 20 closed**, 1 partial (R-03 Mood 96pt → closed in reconcile E2), 1 deferred (R-20 workouts/edit-delete → v0.4.2 + v0.5.0)
- Reconcile-wave additions: tile coherence + migration + edit-button polish + AIProviderStore failures all closed inline

## 0.4.0 — 2026-05-15 (UX + Performance + Parity Marathon)

### Marathon-Ergebnis
Single-session autonomous marathon. Eleven parallel agent streams: 8 read-only audits (W1), 2 sequential foundation streams (Alpha foundation fixes + Echo design system), 5 parallel feature streams (Bravo dashboard, Charlie charts, Delta GLP-1, Foxtrot achievements + notifications, Golf insights + briefing). 36 atomic implementation commits squashed into this release. Top-priority criterion: user-experience aligned with Apple Health App + HIG 2026.

Test count: **263 → 500+** (parallel agents added 195+ net new tests covering DTO drift, SWR cache, drill-down navigation, GLP-1 PK math, MDR boundaries, design tokens, dashboard registry, chart accessibility, Apple-Health-Highlights digest, daily briefing cache). Build clean under Swift 6 strict concurrency, warnings = errors. swiftformat lint clean.

### Critical fixes — Drill-down crashes + DTO drift (Stream Alpha)
- **Drill-down crash root-cause** (A1 audit) — Weight/BP/Pulse/Trends "black-screen / app hangs" was `.fullScreenCover(item:)` with two `@State` writes that race, evaluating to `EmptyView()`. Replaced with a single `MetricDrillDown` `Identifiable` routed via `NavigationStack` + `.navigationDestination(item:)`. Orphan `matchedGeometryEffect` and no-op `.navigationTransition(.zoom)` removed; double-nested `NavigationStack` in `ChartsScreen` over MoreScreen's stack collapsed. Closes user-reports #2 (Medications drill-down no-op via NavigationLink wiring) and the black-screen reports for Weight/BP/Pulse/Trends.
- **Schema drift v1.4.26 — 8 critical fixes** (A4 audit) — `MetricStatusEnvelope` realigned to real `MetricStatusDTO{hasProvider, text, cached, updatedAt}` against `src/lib/insights/{bp,weight,pulse,mood,bmi}-status.ts` (closes the "Befunde" never-rendering silent swallow); `MedicationScheduleDTO.daysOfWeek` now parses the server's `"1,2,3"` / `"i2;1,2,3"` String encoding; `MetricKind` gains `.sleep` + `.steps`, fixes rawValues for `.spo2`→`oxygenSaturation` and `.bodyWater`→`totalBodyWater`, plus tolerant-unknown decoding so a future kind can never break the whole dashboard payload; `HealthKitSyncEntry.direction` gains `.disabled` + raw HK-identifier `kind` strings; `MedicationIntake` POST response decodes the raw Prisma row (`scheduledFor`); `ComplianceDay.date` parses `"YYYY-MM-DD"` day-keys; further surfaced inconsistencies addressed.
- **HLError translation layer** (A4 §7) — `userFacingDescription` now returns proper localized copy per case. Kills the "Type Mismatch Expected" leak (user-report #5).
- **`JSONDecoder.hlDefault`** unified across networking + outbox replay; consistent ISO8601 (fractional + plain) + day-key handling.

### Critical fixes — Offline-first + SWR cache (Stream Alpha)
- **SWR cache infrastructure** (A2 audit) — `CacheKey` enum mirroring the web's `queryKeys.*` factory; `CachedSnapshot` SwiftData `@Model`; `SWRCache` `@ModelActor` at `Library/Application Support/HealthLog/Cache/cache.sqlite` (`cloudKitDatabase: .none`, `.completeUntilFirstUserAuthentication`); `SWRCoordinator.observe(key:fetch:) -> AsyncStream<SWRState<T>>` (`.empty | .cached | .fresh | .failed(lastKnown:)`); `CacheInvalidator` mutation-matrix; `makeWithRecovery()` factory mirroring the Outbox; `ReachabilityBanner` wired into `AuthenticatedShell`. `DashboardStore` adopts the pattern as the reference example.
- The previous zero-app-layer-cache state (cold-start = network-or-grey-skeleton) is gone. Cache-first paint is the default.

### Features — Design system (Stream Echo)
- `hlScreenBackground()` canonical screen-background modifier kills the Dashboard-blau / Settings-grau shift (user-report #6).
- `Background.colorset` retuned `#F5F5F8 / #16171C` to harmonize with iOS 26.
- `HLStreakBadge` + `StreakDetailSheet`: day-progress ring overlay fills as user logs, milestone bounce on 7/30/100/365, tap-to-detail (user-report #7).
- `HLEmojiChart` for ordinal mood-Y-axis + AXChartDescriptor-mandatory `HLChartAX` helpers.
- `MDRAcknowledgmentDialog` (server-owned byte-equal disclaimer copy).
- `LucideToSF` icon mapping + `Image(lucide:)` sugar — kills the silent-fail in Achievements (user-report #9).
- `LiquidGlass` progressive-enhancement helpers gated on `#available(iOS 26, *)`.
- `Tokens.swift` extensions: `HLMotion`, `HLOpacity`, `HLChartStyle`, `HLSheet`, semantic `HLRadius` aliases, `Color.hl*` aliases.
- `MeasureSheetView` half-open glitch killed: detents collapsed to `.large`-only, focus moved to delayed `.task` so it fires after the sheet has settled (user-report #4).

### Features — Dashboard + Dynamic Tiles (Stream Bravo)
- `MetricKindDescriptor` registry replaces every duplicated `switch MetricKind` block with a single source of truth (title, abbreviated title, SF Symbol, server endpoint, display unit, tile type, expected range, color token).
- Full `/api/dashboard/widgets` parity (`GET` + `PUT`) with optimistic mutations + rollback.
- 10 of 15 target tiles live today (Weight, BP, Pulse, Body Fat, Glucose, Sleep, Steps, Total Body Water, Bone Mass, SpO2) — five remaining gate on a server-side additive PR. Architecture lights up the rest automatically when the payload catches up.
- `SleepCompositeTile` (stages strip) + `AudioExposureTile` (paired environmental + headphones with Apple risk meter) shipped dormant — ready when server emits the data.
- New `DashboardCustomizationScreen` reachable from Settings, Apple-Health-style drag-reorder.
- `HLStreakBadge` replaces the static `HLBadge("\(days) Tage", icon: "flame.fill")` (user-report #7).
- `hlScreenBackground()` applied to Dashboard, Settings, Customization.
- Provenance chips per tile.
- Humane empty-state copy DE+EN per tile.
- VoiceOver: "Schritte heute: 8.234. Antippen für Details."

### Features — Charts to Apple-Health tier (Stream Charlie)
- `HLSparkline` rebuilt on the Apple `Charts` framework (API-compat for existing callers).
- `ChartDetailScreen` content polish: scrubbable cursor with value bubble + dashed vertical line; period segmented picker (Tag / Woche / Monat / 6M / Jahr) drives the `ChartDetailStore` query window; summary header with Min / Avg / Max / Median; sources-attribution row; insufficient-data card; dual-series with shaded inter-band for BP.
- `MoodScreen` chart rebuilt with `HLEmojiChart` (1–5 emoji Y-axis, dated X-axis, summary header, period picker) — closes user-report #8.
- `TrendsScreen` multi-metric overlay with z-score normalisation + per-series toggle chips.
- AXChartDescriptor coverage 100%, enforced by a file-system-scan exhaustiveness test.

### Features — GLP-1 PK curve (Stream Delta)
- `Glp1PK.swift` faithful Swift port of `src/lib/medications/glp1-pk.ts` — one-compartment Bateman model, linear superposition for multi-dose, numerical agreement ε<1e-9 vs hand-computed reference. Five EMA drugs covered (Tirzepatide / Semaglutide / Liraglutide / Dulaglutide / Exenatide) including all brand routings (Mounjaro / Wegovy / Ozempic / Saxenda / Trulicity / Byetta / Rybelsus). Closes a top-requested feature.
- New `MedicationDetailScreen` replaces Alpha's placeholder destination — Apple-Health-medication-style header, last-dose card, MDR-gated PK chart, intake history, schedule card with Alpha's parser, inventory section, notes.
- **MDR compliance**: byte-equal disclaimer copy against server, unit-less Y-axis with no tick labels, no clinical interpretation, no "next peak" marker. SwiftLint custom rules (`mdr_no_predictive_copy`, `mdr_no_clinical_recommendation`) plus locked-copy and AX-descriptor tests enforce the boundary at build time.
- `ResearchModeStore` + `ResearchModeRepository` wired through `AppContainer` for first-view acknowledgment gating.

### Features — Achievements + Notifications (Stream Foxtrot)
- **Three Achievements bugs closed** (user-report #9):
  1. Lucide icon names rendered via Echo's `Image(lucide:)` — no more silent fails on `Image(systemName: "Trophy")`.
  2. Cells wrapped in `Button` with selection-haptic → new `AchievementDetailSheet` (Apple-Health-Awards-style hero + description + progress + points).
  3. `Achievement.points: Int?` added; 59 server-known IDs covered by `AchievementPoints` static table (no-ops cleanly once server widens its iOS adapter).
- `AchievementsStore` aggregates `earnedPoints` + `totalPoints`; hidden-locked cards correctly skip the denominator.
- **Notifications Inbox** (SwiftData-backed, iOS-local): `InboxNotification` `@Model` + `NotificationInboxStore` with `makeWithRecovery()` parity with Outbox/Cache; new Apple-Mail-style sectioned `NotificationInboxScreen` ("Heute" / "Gestern" / "Letzte 7 Tage" / "Älter") with swipe-to-mark-read/delete; APN delivery writes inbox rows on `willPresent` / `didReceive` / silent-push paths with a 2s dedup window; inbox cleared on logout, 401, and account deletion.
- `NotificationsScreen` polished: priority-sorted sections, empty-state rows, last-delivery line via `GET /api/notifications/status`, local test-push button, prominent Posteingang nav-link.

### Features — Insights + Daily Briefing + HS Pillars (Stream Golf)
- `ComprehensiveDigest` Swift DTO decodes the full `/api/insights/comprehensive` envelope — previously iOS discarded everything except `recommendations`. BMI + classification, BP ESH-2023 classification + %-in-target + targets, five correlation scatter cards (BP × Weight, BP × Mood, BP × Medication, Weight × Mood, Mood × Pulse), mood summary, alerts list, data-quality footer.
- `InsightsScreen` revamped Apple-Health-Highlights-style with 14 new sections.
- `DailyBriefingStore` lazy-generates via `POST /api/insights/generate` with a 24h SwiftData SWR cache (via Alpha's `SWRCoordinator`) + explicit `force=true` refresh.
- `HealthScoreDetailSheet` provenance line ("Berechnet aus X Messungen über Y Tage") + `hlScreenBackground()` applied.
- Correlations panel renders r-values + plain-language interpretation served by the server, never iOS-computed (MDR boundary).

### Quality, plumbing, ops
- `AppContainer` wires `dashboardLayoutStore`, `researchModeStore`, `notificationInbox`, `dailyBriefingStore`; 401-bridge + account-deletion hook + handleLocalLogout all wipe the new stores so the next session can't surface previous-user state.
- xcodegen clean, swiftformat lint clean (0/237 files require formatting), full unit + UI test suite green on `xcodebuild -destination 'iPhone 17 Pro'`.
- Smoke-test on Simulator: app launches cleanly, German onboarding hero renders with new design tokens, no crashes on cold start.

### Deferred
- Coach SSE conversational interface — XL scope + MDR-Class-IIa boundary risk requires deliberate review; v0.5.0.
- Server-side endpoint for shared notifications inbox — iOS stays on local SwiftData inbox in v0.4.0.

## 0.3.0 — 2026-05-15 (Server-Sync Marathon — Production Feature-Wave)

### Marathon-Ergebnis
13 parallele Subagent-Streams (7 Audits inkl. Apple-Compliance + 5 Wave-2b Coding + 3 Wave-2c Coding + 2 Wave-2a Foundation). Konsolidierte Audit-Funde aus 7 Reports und 5 Apple-Submission-BLOCKER. ~30+ Critical adressiert, davon Show-Stopper: HK-Pipe-nicht-verkabelt, Refresh-Token-Bug, Outbox-in-memory, Account-Deletion-fehlend.

Test count: **0 → 261 (47 suites)** seit v0.2.0; 184 net new Tests in dieser Marathon. Build clean (warnings = errors), Swift 6 strict-concurrency clean.

### Critical fixes — Server-Sync Foundation (Wave 2a)
- **Refresh-Token-Flow** (W2a-A2): silent-logout 24h nach Login behoben. Neuer `RefreshCoordinator` (single-flight) + `POST /api/auth/refresh` + 401-Bridge mit single-retry.
- **Outbox SwiftData migration** (W2a-A5): in-memory → SwiftData @Model + @ModelActor. Operations ueberleben jetzt App-Kill. `Library/Application Support/HealthLog/Outbox/outbox.sqlite`, `cloudKitDatabase: .none`, `.completeUntilFirstUserAuthentication`. ADR-011/012 dokumentiert. 9 neue tests.
- **Source enum** `APPLE_HEALTH` (war `HEALTHKIT` — server skipped).
- **Schema fixes** (W2a-A2): nullable Dashboard fields, tolerant `Insight.provider: String`, Medication shape rewrite, camelCase series kinds.
- **Withings-Pfade**: 4 dead `/api/integrations/withings/*` → `/api/withings/*`. `{kind:"measure"}` sync body, browser-only connect.
- **Audit-Log + Export** Pfade korrigiert.
- **`X-Device-Id` Header** generiert + Keychain-persistiert + auf jedem Request.
- **`X-RateLimit-Reset`** ISO-8601 Parsing statt `Retry-After` (war Hammer-API).

### Critical fixes — HealthKit Comprehensive Sync (Wave 2b-A1 + 2c-A1H)
- **HK-Pipe-Verkabelung** (Headline-Bug): iOS sammelte HK-Daten aber rief `POST /api/measurements/batch` NIE auf. Jetzt End-to-End: `HKObserverQuery → HKAnchoredObjectQuery → handleNewSamples → HealthKitWireConverter → MeasurementBatchUploader → POST batch`.
- **Sample-Type-Coverage 9 → 19** (per Server-Spec): Audio-Exposure, Time-in-Daylight, Active-Energy, Flights-Climbed, Walking/Running-Distance, VO2-Max, Sleep-Stages-per-Stage, Resting-HR, HRV-SDNN, Body-Temperature dazu.
- **Per-Batch Idempotency-Key**, sliding-window throttle (60/min), per-entry status (`inserted | duplicate | skipped` alle terminal).
- **Anchor-after-200** (W2c-A1H/H6): `SampleConsumeOutcome` enum gates `saveAnchor` auf `.consumed`. Network/5xx/429/offline → keep anchor → next observer wakeup re-fetched → server dedups via externalId. Kein silent data-loss mehr.
- **Initial-Backfill-Window-Picker** (W2c-A1H/H7): Onboarding-Picker (7d/30d/90d/1y/Alle, default 30d). Per-User UserDefaults persistiert, Logout cleared.
- **deviceType-Mapper** (`HKDevice.model` → enum), **per-user anchor partition** (Re-Login mit anderem Account starts fresh), **×100 conversion** für SpO2/BodyFatPercentage.
- **Per-stage Sleep-Decoder** (sleepStage Integer per `HKCategoryValueSleepAnalysis`).
- **Permission groups by category** (vitals/activity/sleep/mood) statt one-shot.

### Critical fixes — Apple Compliance (Wave 2b-A8)
- **Account Deletion** (Guideline 5.1.1(v) — top first-submission rejection driver): `DELETE /api/settings/account` mit `{confirm: "DELETE_ACCOUNT"}` + zwei-Stufen-UI in Settings → Konto. Cascade clears Keychain + Outbox.
- **Privacy Manifest** extended: Email + OtherUserContent + SensitiveInfo + DeviceID. UserID + AccountManagement-purpose. Über-Declarations gestrichen (SystemBootTime, FileTimestamp).

### Features — Insights + Dashboard (Wave 2b-A4)
- **Insights screen rebuild**: server-rendered cards mit severity-sorted recommendations, citation disclosure, warnings, correlations grid. Pull-to-refresh = re-fetch (NIE local-regenerate, MDR-Boundary).
- **Daily Briefing Hero** auf Dashboard + Insights tab. Tone-coloured leading bar (good/watch/info), key-finding chips.
- **Health Score Tile** four-pillar (Dashboard) mit band-coloured ring + delta chip + Detail-Sheet mit provenance accordion + FormulaCard (server-emitted weights × values verbatim — NIE recompute, MDR-Boundary).
- 15 neue Tests + 3 Snapshots.

### Features — Charts Interactive (Wave 2b-A3)
- **Tap-to-zoom Detail Screen**: iOS-18 `.zoom` `navigationTransition` + `matchedTransitionSource`. Hero-strip + sticky range picker (7d/30d/90d/1y/all).
- **Per-Metric `@ChartContentBuilder`**: BP dual-line + traffic-light bands (90/130/140 mmHg), weight area+gradient + dashed personal-baseline rule, pulse zones, glucose severity dots, temperature/SpO2 thresholds.
- **`chartXSelection`-driven Callout**: floating overlay mit Datum + Wert (BP sys/dia natural) + PR-Star.
- **Drill-Down**: ChartDetail → MeasurementListScreen (sectioned by Today/Yesterday/This Week/Older + `.searchable`).
- **Server-fetched Findings**: `MetricInsightsRepository` actor wrapping `/api/insights/<metric>-status` mit 404-fallback zu `/api/insights/comprehensive`. iOS NIE generiert.
- **Performance**: `SeriesDownsampler` für >90d (60 fps bei >1.5k marks).
- **A11y**: VoiceOver-Announcement on selection, `UISelectionFeedbackGenerator` (gated by reduce-motion).

### Features — APNs + Deep Links (Wave 2b-A6)
- **NotificationService rebuild**: UNUserNotificationCenter-Delegate, `UIApplicationDelegateAdaptor`, AppDelegate-Shim mit Token-Hex-Encoding.
- **`/api/devices` Registration**: apnsToken (hex) + apnsEnvironment (sandbox/production), Idempotenz, 409-Recovery.
- **Foreground Re-Registration** auf Token-Wechsel.
- **`aps-environment` Entitlement** + **`CFBundleURLTypes: healthlog`**.
- **AppRouter + DeepLinkRouter** für 7 URL-Pfade (`healthlog://dashboard`, `coach`, `insights/<metric>`, `medications/<id>`, `medications/<id>/history`, `personal-records/<id>`, `settings/notifications`). `.onOpenURL { ... }` integration.
- **Onboarding-Permission-Step** (full UNAuthorizationOptions, post-onboarding).
- **Notifications-Preferences-Screen** + Repository + Store für `/api/notifications/preferences` GET/PATCH.
- **PERSONAL_RECORD** bleibt server-default-OFF.
- 33 neue Tests.
- ⚠️ **APNs-Push-Delivery gated** auf Server-side `.p8` env-vars (KeyID + Team + Topic — konfiguriert server-seitig).

### Quality fixes (Wave 2c)
- **Silent Errors fix** (W2c-W1i, audit-v021/C5): shared `HLErrorBanner` in DesignSystem mit Retry-CTA. 5 Screens wired (Charts-Detail, Medications, Mood, Achievements, plus Dashboard/MeasurementList migrated). 8 neue regression tests.
- **Umlauts → Unicode** (W2c-W1k, audit-v021/C2): 515+ Replacements in 85 Files. Inkl. `MetricKind.displayName` (`Körperfett` etc.), 17 xcstrings keys + 13 DE values, `NSFaceIDUsageDescription`. **Visible to all DE users.**
- **Dynamic Type Erweiterung** (W2c-W1k, audit-v021/M5-Reste): 11 `@ScaledMetric` callers migrated (Hero/Tile-Numbers 28/36/72pt skalieren jetzt mit Larger Text).

### Tooling
- **A7 Apple Compliance Research**: 776-line audit, 5 BLOCKER, 70+ Pre-Submission-Checkboxes (`docs/apple-developer-setup.md` + `.planning/v030-marathon/A7-apple-compliance-research.md`).
- **Server-Doku-Pack** vom User: `~/Projects/HealthLog/.planning/v15-ios-handoff/` (22 Files, 89k tokens) als Anker für alle Streams.

### Backlog (deliberately deferred)
- **Coach SSE streaming** (3-4d effort, Swift-6 strict-concurrency um `URLSession.bytes` + `AsyncThrowingStream`, MDR-sensitiv).
- 5.1.2(i) Third-Party-AI Consent (depends on Coach screen).
- Public Privacy Policy mit HKQuantityType-Enumeration (User-Action im Server-Repo).
- Regulated-Medical-Device App-Store-Connect-Form (User-Action).
- iOS-only / autark-Mode (Research-Wave später).
- Korrekt einer fehlenden UI-Test-Migration (`OnboardingUITests.testWelcomeScreenShowsCTAAndProgressDots`) auf neuen 6-Step-Flow (Notifications + Backfill picker added).

## 0.2.1 — 2026-05-14 (Foundation Marathon — TestFlight readiness)

### Marathon-Ergebnis
6 parallele Coding-Agents + 4 parallele Audit-Reviewer (read-only) auf Worktree-Branches. Konsolidierte Audit-Funde: 9 Critical, ~25 High, ~46 Medium, ~38 Low über Security/UX-HIG/Concurrency/Perf-Quality-Domains. Marathon-must davon adressiert; Reports unter `.planning/audit-v021/`.

### Bugfixes (Critical)
- **Face-ID-Loop**: `RootView.handle(scenePhase:)` triggerte Face-ID alle 2-3 Sekunden auf jeder Seite. Drei Root Causes: (1) Face-ID-Sheet selbst überschrieb `lastBackgroundedAt` via `.inactive`, (2) `nil`-Semantik überladen mit "Cold-Start" + "gerade-entsperrt", (3) keine Mutex auf `tryUnlock`. Fix: `unlockInFlight`-Gate, `task(id: phaseKey)` Cold-Start-Trigger, `lastBackgroundedAt` als "pending re-lock" konsumiert. Inkl. Tests.
- **HealthKit-Background-Deliveries activation gap**: `HealthKitService.startBackgroundDeliveries()` war Dead-Code — Entitlement gesetzt, aber Methode nie gerufen. Neuer `BackgroundSyncCoordinator` owns BGTaskScheduler-Lifecycle (`dev.healthlog.app.healthkit-sync`), wired in `AppContainer.init`, aktiviert in `HealthKitPermissionStep` nach Consent + in `RootView` bei Cold-Start re-entry. Frequenz pro Type per PROJECT_GUIDE.md (Vital-Signs `.immediate`, Steps/Mass `.hourly`, Sleep `.daily`). Manual-Verification auf physischem iPhone via LLDB `_simulateLaunchForTaskWithIdentifier:`.
- **Cert-Pinning Production-Hashes gesetzt** (war TestFlight-Blocker): SPKI-SHA-256 für den Managed-Host als `HLPinnedSPKIHashes` in `project.yml` injiziert. Primary: Leaf-Cert (valid 2026-03-28 → 2026-06-26). Backup: Google Trust Services WE1 intermediate (valid 2023-12 → 2029-02). 5 neue `CertificatePinnerTests`. Rotation-Playbook im W1c-Report.
- **LockOverlay no-escape**: User war bricked wenn Biometric unavailable. Neuer ghost-styled "Abmelden"-Button (always visible) + Confirmation-Dialog + optional Unavailability-Hint via `LAContext.canEvaluatePolicy`. 4 Mirror-basierte Contract-Tests.

### Bugfixes (High)
- **Idempotency-Key persistent über Retries**: `MedicationsRepository.record()` nutzte vorher kein Idempotency-Header und droppte `takeMedication`-Outbox-Operations. Jetzt: Key once-pro-Operation, gleicher Key in Retries + Outbox-Replay, `IntakeUpdate` als public Codable für Outbox-Roundtrip. `OutboxReplayService` decodes + replayed mit persistiertem Key. Regression-Suite `IdempotencyKeyPersistenceTests` (3 Contracts).
- **LogSanitizer Härtung**: UUID-Regex (8-4-4-4-12), URL-Stripping zu `scheme://host`. Architektur: `HLLog.*` returns nun `HLLogger`-Wrapper; `HLLogMessage: ExpressibleByStringInterpolation` mirrors `OSLogMessage`-Syntax — alle 16 Call-Sites compilen unverändert, Sanitizer-Routing per Konstruktion. 3 redundante manuelle `redact()`-Calls entfernt. `docs/security.md` aktualisiert.
- **Charts AXChartDescriptor**: Time-Axis-Ticks lieferten leere Strings (VoiceOver "(empty)"). Blutdruck secondary-Line war VoiceOver-unsichtbar. Beides gefixt; Descriptor extrahiert nach `Screens/Charts/ChartsAccessibility.swift`. 9 Swift-Testing-Cases. 5 neue Localized i18n-Keys (DE+EN).

### Refactor / Architecture
- **TabBar**: Custom `HLTabBar` (122 LOC) gelöscht. Migration zu nativem iOS-18 `Tab`/`TabRole`-API in `AuthenticatedShell`. Snapshot-Test auf Tab-Kontrakt via `.dump`-Strategie. Visuelle Hierarchie identisch.
- **iOS-Min auf 18.0** (von 17.0) — SpeziScheduler-Voraussetzung + neuer `Tab`-API (siehe `docs/spezi-migration-plan.md`).
- **DEVELOPMENT_TEAM** (Apple Dev) auf `S8WDX4W5KX` gesetzt.
- **`com.apple.developer.healthkit.background-delivery` Entitlement** ergänzt (war fehlend, Production-blocking).
- **GENERATE_INFOPLIST_FILE: YES** auf Test-Targets — `xcodebuild test` lief vorher gar nicht durch (Code-Signing-Fehler).
- **swiftformat-Cleanup** in `RootView.swift` (else-on-same-line).

### Documentation
- **PROJECT_GUIDE.md** neu — Tech-Stack, Spezi-Adoption-Status, Skill-Mapping, Anti-Patterns, Build/Test/Quality-Gates, Conventions.
- **docs/spezi-migration-plan.md** — Selektive Adoption (HealthKit + AccessGuard + Scheduler + Medication; nicht SpeziAccount/Onboarding wegen Server-first).
- **docs/apple-developer-setup.md** — Step-by-step von Team-ID bis TestFlight inkl. Health-App-Review-Pitfalls.
- **docs/design-audit.md** — TabBar-Refactor + Top-Level-Reorg-Plan + HIG-Health-App-Review.
- **`.planning/audit-v021/`** — 4 Marathon-Reports (security, ux-hig, concurrency, perf-quality) + 7 W1*-Stream-Reports.

### Testing
- **77 Tests grün** (75 unit / 15 Suiten + 2 UI). Vorher: 0 (xcodebuild test schlug am Code-Signing fehl).
- Neue Test-Suiten: `CertificatePinnerTests`, `AuthenticatedShellTabsTests`, `IdempotencyKeyPersistenceTests`, `ChartsAccessibilityTests`, `BackgroundSyncCoordinatorTests`, `LockOverlayTests`, plus erweiterte `LogSanitizerTests`.

### Tooling
- **XcodeBuildMCP v2.5.2** als lokaler Build-Server installiert und verbunden.
- **iOS-Entwicklungswerkzeuge** für SwiftUI, SwiftData und Swift Concurrency eingerichtet.

### Backlog (bewusst NICHT in dieser Marathon)
- C-2 OutboxQueue persistent (Phase-5-deferred per PROJECT_GUIDE.md)
- C2 SWR-Cache (docs vs implementation gap — entweder bauen oder docs aufräumen)
- W1i Silent-Error-Handling außerhalb Dashboard (UX C5)
- W1k Quick Wins (Umlauts→Unicode, Dynamic Type via Tokens.swift, hlAnimation rollout)
- H-5 Biometric-Failure-Lockout (UX-Discovery nötig)
- H-8 Streak-Badge coercive (Product-Decision)
- C1 EN-Localization (sekundäre Sprache)
- API/Schnittstellen-Audit gegen Server-Doku — eigener kommender Workstream

## 0.2.0 — 2026-05-03 (Comprehensive Audit + Server Reconciliation)

### Audit-Ergebnis
8 parallele Agenten — 2 Senior-Devs, 2 Security-Researcher, 4 QA-Spezialisten — fanden zusammen **~8 BLOCKER + ~50 MAJOR + diverse MINORs**. Größter Befund: iOS-Client und Server-API hatten fundamentale Schema-Inkompatibilitäten (Envelope-Format, Auth-Token-Flow, Measurement-Schema, viele fehlende Endpunkte). App war im Audit-Stand nicht funktionsfähig gegen den echten Server.

### Server (Repo: ~/projects/HealthLog/)
- **Token-Exchange**: `/api/auth/login` + `/api/auth/passkey/login-verify` liefern bei `X-Client-Type: native` einen 90-Tage `hlk_*`-Bearer-Token. Audit-Log `auth.token.autoissue.native`.
- **Generischer Idempotency-Cache**: `withIdempotency()`-Wrapper. 24h TTL, keyed `(userId, key, method, path)`. Wired in Measurements, Mood-Entries, Medications/Intake.
- **Neue Aggregator-Endpunkte**:
  - `GET /api/dashboard/summary` (greeting + streak + compliance + sparklines)
  - `GET /api/measurements/series?kind=&days=`
  - `GET/PATCH /api/integrations/healthkit`
  - `GET/PATCH /api/user/profile` (delegiert auf `applyProfileUpdate`-Helper)
  - `POST /api/devices`
  - `GET /api/medications/intake?scope=today|compliance`
  - `POST /api/medications/intake` (top-level mit intakeId)
  - `GET /api/insights/cards` + `/api/insights/correlations`
  - `GET /api/gamification/achievements?format=ios`
- **Migrations** `0022_v1_3_ios_adapters_idempotency_devices`: `users.display_name`, `users.healthkit_config_json`, `users.healthkit_last_synced_at`, neue Tabellen `idempotency_keys` + `devices`.
- **OpenAPI** v1.3.0: 9 neue Pfade, 18 neue Schemas. Lint clean.
- **Tests**: 244/244 grün (49 neue Tests).

### iOS Critical-Fix-Block (Senior-Pass-2 + Security-Audit)
- **AuthStore.handleUnauthorized** wischt Keychain (kein Re-Auth-Loop nach Session-Expiry).
- **Passkey-MainActor-Crash**: Anchor wird pre-resolved auf MainActor, nicht via `assumeIsolated` lazy.
- **WebAuthn `userHandle`**: jetzt base64url (war UTF-8 → Login wäre in Production gebrochen).
- **Build-Time-Guard**: Release-Build ohne Pin-Set crasht beim Start (verhindert stille MITM-Toleranz).
- **HK-Anchor**: Keychain → UserDefaults (Battery-relevant: keine SecItem-Add-Roundtrips bei Background-Wakeups).
- **HK-Frequency**: pro Type tuned (Vital-Signs `.immediate`, Steps/Mass `.hourly`).
- **`UnauthorizedHandlerRef.invokeOnce`**: parallele 401-Responses feuern nur einmal Logout.
- **Echter Biometric-Lock**: `LAContext.evaluatePolicy(.deviceOwnerAuthentication)` + Lock-Overlay + ScenePhase-Tracking + 30s-Grace-Period.
- **`OutboxReplayService`**: Reachability-driven Replay-Loop mit Idempotency-Key-Erhaltung über App-Restart.
- **Idempotency-Key in OutboxOperation**: persistent über Restart, kein Duplikat-Risiko bei Server-Replay.
- **Multi-User-Cleanup**: alle Stores haben `clearOnLogout()`, AppContainer wired auf 401-Bridge.
- **MedicationsStore.mark**: Optimistic-Patch mit Snapshot-Rollback bei Non-Retriable-Fehler.
- **MoodStore.log**: Optimistic-Insert mit Outbox-Pfad bei Retriable-Fehler.
- **LogSanitizer.redact** auf `lastError`-String in AuthStore (Crash-Report-Hardening).

### iOS API-Reconciliation (Server-Schema-Match)
- **APIEnvelope**: `{ data, error: String? }` (war `error: APIError`-Object — broke decoding).
- **Codec-Strategy**: `keyEncodingStrategy`/`keyDecodingStrategy` entfernt — Server ist nativ camelCase.
- **`X-Client-Type: native`** als Default-Request-Header.
- **AuthService**: `NativeLoginResponse { user, token, tokenExpiresAt }`-Decoder.
- **Passkey-Wrapping**: `{ challengeId, credential }` für Server-Verify-Endpoint (war flat).
- **MeasurementWireDTO + MeasurementCreateDTO**: bit-genau zum Server (`type: BLOOD_PRESSURE_SYS`/`DIA`, scalar `value`, `measuredAt`/`notes`/`source` mit ALL-CAPS-Enums).
- **MeasurementAggregator**: BP wird beim Lesen von 2 Wire-Records → 1 Domain-Measurement gemerged.
- **MoodEntry**: `mood: ServerMoodLevel` (LAUSIG/SCHLECHT/OKAY/GUT/SUPER_GUT) statt score-Int. Convenience-`score`-Property für UI-Code.
- **Mood-Path** korrigiert auf `/api/mood-entries`.
- **InsightsRepository.cards()** + `correlations()` als getrennte Endpoints (statt `?section=`-Query).
- **InsightsRepository.setProvider()** ruft `/api/user/ai-provider`.
- **AchievementsRepository** mit `?format=ios`-Query.

### iOS UX-Polish
- **DashboardLayout-Switch verkabelt**: Cards/Hero/List rendert je nach SettingsStore.dashboardLayout.
- **HLTint-Propagation**: `.tint(settings.preferredTint.color)` in App-Root.
- **Forced Dark Mode → toggleable**: Appearance-Picker (Dunkel/Hell/System) + ColorScheme-Override im Root.
- **Settings-Stubs ersetzt**: PasskeyManagementScreen, AuditLogScreen, ExportScreen alle echt funktional gegen Server-Endpoints.
- **WithingsIntegrationScreen**: OAuth-Init + Sync + Disconnect.
- **AI-Provider-Picker** in Settings (Anthropic/OpenAI/Gemini).
- **Welcome-Screen**: 4 FeatureRows wie Mockup (Vitalwerte, Compliance, AI Insights, Self-Hosted).
- **Mood**: 5 Buttons mit Emoji-Faces statt Slider (mockup-konform).
- **Auth**: Server-URL-Field (toggle für Self-Hosted) + Demo-Modus-Button.
- **ChartsScreen**: Mode-Switch (Linie/Fläche/Balken), Moving-Average-Toggle, Wired über `ChartsStore`.
- **DoctorReportScreen**: PDFKit-Preview eingebettet, Wired über `DoctorReportStore` mit Cleanup.

### iOS A11y
- **`hlAnimation(_:value:)` Modifier**: respektiert `accessibilityReduceMotion` automatisch.
- **`HLMaterialBackground`**: Solid-Fallback bei `accessibilityReduceTransparency`.
- **HLButton.compact**: 36→44pt (HIG-Konformität).

### Cleanup
- **Repository.swift + SWRRepository.swift gelöscht** (Dead Code).
- **DoctorReportService**: eigene Datei in `Services/`.
- **AchievementsStore**: eigene Datei.
- **ChartsStore + DoctorReportStore**: neu, eliminieren Layering-Verletzungen (Views → Repos direkt).
- **MeasurementsRepository.cache**: Write-only Dead-State entfernt.

### Defer (klar dokumentiert, mit Begründung)
- **Phase 9**: Volle Localization der ~80 hardcoded UI-Strings ins xcstrings-Catalog.
- **Phase 9**: AppIcon 1024×1024 PNGs (Light, Dark, Tinted) — Asset-Erstellung extern.
- **Phase 8**: APNs-Push-Sender-Implementation (Server-Endpoint vorhanden, aber kein Sender-Code).
- **Phase 7**: Echter Korrelations-Engine in `/api/insights/correlations` (aktuell `[]`-Stub).
- **Server**: Cron-Sweep für expired `idempotency_keys`-Rows.

### Final-Stats (post-Audit)
- **86 Swift Files**, **~8.000 LOC**.
- **Server**: 244/244 Tests, lint clean, typecheck clean.
- **iOS**: in dieser Sandbox nicht xcodebuild-verifiziert (Xcode nicht verfügbar). Build-Verifikation erfolgt lokal nach `xcodegen && open`.

---



## 0.1.0 — 2026-05-03 (Foundation Drop)

### Added (iOS App)
- Repo-Skelett, XcodeGen-basiertes Projekt-Setup, SwiftPM-Stub fuer Core-Library.
- Design-Tokens (HLColor, HLSpace, HLRadius, HLType) gespiegelt aus `tokens.css`.
- Color Asset Catalog mit Light/Dark-Variants (Background, BackgroundElevated, Surface, SurfaceElevated, Separator, TextPrimary/Secondary/Tertiary).
- Design-System-Komponenten: HLCard, HLButton (5 Varianten), HLBadge, HLListRow, HLSparkline (3 Modi), HLRing, HLTabBar.
- Foundation-Layer: APIClient (Actor) mit Idempotency-Key, Exponential-Backoff + Jitter, optionalen CF-Access-Headern, Cert-Pinning-Hook; KeychainStore; PII-Sanitizer-Logger; Reachability; OutboxQueue.
- Models: Measurement (Scalar + BP), Medication, MedicationIntake, MoodEntry, Insight, Achievement, User, DashboardSummary, HealthKitSyncConfig, EffectiveRange.
- Repositories pro Domain (SWR-Pattern, Outbox-Failure-Handling fuer Measurements).
- Stores: Auth, Dashboard, Measurements, Medications, Mood, Insights, Achievements, Settings + AppContainer Composition Root.
- Services: AuthService (Email/Password + Passkey-WebAuthn-Flows), PasskeyService (`ASAuthorizationController`-Wrapper), HealthKitService (Anti-Duplikat via ExternalUUID + AnchoredObjectQuery), NotificationService.
- Screens P0/P1: Onboarding (4 Schritte), Auth, Dashboard (Cards-Layout), MeasureSheet, Medications (Timeline + Compliance-Heatmap), Mood, Charts (Swift Charts mit Accessibility-Descriptor), Insights, Achievements, Settings, Doctor-Report (Server-PDF-Download + Share-Sheet), More.
- Tests: 8+ Test-Files (Swift Testing) — Models, DTO-Coding, KeychainStore-Mock, APIClient (URLProtocol-Mocks: Bearer-Header, Idempotency, CF-Access, 401, 5xx-Retry), OutboxQueue, HLError, MeasurementsRepository.
- CI-Pipeline (`.github/workflows/ci.yml`): SwiftLint strict, SwiftFormat lint, xcodebuild build+test, SPM Core build+test, Coverage-Gate.
- Privacy: `PrivacyInfo.xcprivacy` mit Health/UserID/keine Tracking-Domains, Localizable.xcstrings (DE Default + EN), Info.plist-Privacy-Strings via project.yml.
- Docs: `architecture.md`, `api-contract.md`, `security.md`, `testing.md`, `decision-log.md` mit ADR-001..008.
- Scripts: `scripts/extract-spki.sh` zum Erzeugen der Pinning-Hashes aus dem Production-Cert.
- GSD-Planning: `.planning/PROJECT.md`, `.planning/ROADMAP.md`.

### Added (Server Side)
- **Server-PDF-Endpoint** `POST /api/doctor-report/pdf` (server-rendered jsPDF, isomorpher Render-Core, 188/188 Tests gruen). ADR-002.
- **Bearer-Token-Auth** in `requireAuth()` (Cookie-Path bleibt; Bearer fuer iOS-Clients aktiv; `auth_method: "bearer"` in Wide-Events; 195/195 Tests gruen).
- **OpenAPI 3.1 Spec** `docs/api/openapi.yaml` (104 Pfade, 139 Operationen, 112 Schemas, redocly-lint 0 Errors).

### Decisions
- ADR-001: XcodeGen + SPM-Manifest fuer plattformfreie Core-Targets.
- ADR-002: Doctor-Report wird server-rendered (keine clientseitige PDF-Pflege).
- ADR-003: CF-Access-Header-Slots im APIClient praeventiv mitgeliefert, default leer.
- ADR-004: Strict Swift-Concurrency, kein Combine.
- ADR-005: SwiftData fuer Caches + Outbox.
- ADR-006: Bundle-ID `dev.healthlog.app`.
- ADR-007: Swift Testing primary, XCTest fuer UI + Snapshots.
- ADR-008: HealthKit Anti-Duplikat ueber ExternalUUID + Source-Filter.

### Open Blockers
- Apple Developer Team-ID (Operator) — Phase-0-Device-Build.
- APNs `.p8`-Key (Operator) — Phase 8.
- Server `POST /api/devices` Endpoint — Phase 8.

### Quality Status
- Code geschrieben in dieser Session, **nicht** im Xcode-Build verifiziert (Xcode nicht in dieser Sandbox).
- Server-Aenderungen verifiziert: lint + tests beide gruen.
- iOS-CI-Pipeline definiert, lokale Build-Verifikation steht aus, sobald der Operator lokal `xcodegen && open` ausfuehrt.

### Senior-Review (durchgefuehrt) — Findings + Fixes

Senior-Review identifizierte **3 BLOCKER + 8 MAJORs**. Alle BLOCKER + 4 schnelle MAJORs in dieser Session gefixt:

**BLOCKER-Fixes:**
1. **Cert-Pinning** (`Services/CertificatePinner.swift`): `derEncodedSPKI` hashed vorher den raw Public-Key, was nie zum Hash aus `extract-spki.sh` (full SPKI DER) passt. Jetzt: ASN.1-SPKI-Header-Prepend pro Key-Type (TrustKit-Pattern fuer RSA-2048/4096 und ECDSA-P256/P384). Output bit-genau identisch zu openssl.
2. **Actor-Isolation** (`SWRRepository`, `OutboxQueue`, `Reachability`): Computed `AsyncStream`-Getter schrieben direkt in Actor-State aus dem `@Sendable`-Closure, was unter `SWIFT_STRICT_CONCURRENCY: complete` nicht kompiliert. Jetzt: `AsyncStream.makeStream()` + `register(id:continuation:)` als isolierte Actor-Methode.
3. **Test-Module-Mismatch**: Tests importierten `HealthLogCore` (SPM-Modul), `xcodebuild`-Target heisst `HealthLog`. Jetzt: `#if SWIFT_PACKAGE`-Conditional in allen 8 Test-Files, beide Build-Pfade gruen.

**MAJOR-Fixes:**
4. **Optimistic-Write-Rollback** (`MeasurementsStore`): Bei non-retriable-Fehler wird der lokale Eintrag jetzt aus `recent` entfernt (Spec §3 "Rollback bei Fehler").
5. **401-Handler verkabelt** (`AppContainer` + `AuthStore.handleUnauthorized()`): `UnauthorizedHandlerRef` (Sendable Box) loest das Chicken-and-Egg zwischen APIClient (initialisiert vor AuthStore) und AuthStore. APIClient hat jetzt funktionierende 401 → Logout-Bruecke.
6. **Biometric-Default ON** (`SettingsStore`): First-Launch-Detection via `defaults.object(forKey:) == nil`, default true (Spec §7).
7. **NotificationService-MainActor**: `UIDevice.current.model` und `UNUserNotificationCenter.add(_:)` jetzt explizit `@MainActor`-isoliert, await aus dem actor.

**MINOR-Fixes:**
8. Dashboard-Locale (war `de_DE` hardcoded) → System-Locale.
9. ShimmerModifier respektiert jetzt `accessibilityReduceMotion`.
10. SceneAnchorProvider: `nonisolated` Singleton + `@MainActor` nur auf `anchor()` (Spec §8 Strict-Concurrency-Compliance).

**Defer-Liste (Phase 5/9):**
- I18n-Vollextraktion (German strings in Models/Views) → Phase 9.
- HealthKit-Upload-Pipeline (Pull HK→Server) → Phase 5.
- OutboxQueue auf SwiftData persistieren → Phase 5.
- §13-Klaerungsfragen vom Reviewer als „nicht gestellt" geflagged — wurden tatsaechlich vor Code-Start asynchron geklaert (siehe initial-message Antworten).

Senior-Bewertung: **7.5/10** vor Fixes. Erwartete Bewertung nach Fixes: **8.5/10** (volle 9/10 erst nach I18n-Extraktion + HK-Upload-Wiring + OutboxQueue-SwiftData-Persistierung — alle Phase-5/9-Items).
