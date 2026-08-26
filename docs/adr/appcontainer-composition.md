# ADR — `AppContainer` composition root: flat store block + Mirror logout sweep

- Datum: 2026-06-26
- Status: Accepted
- Kontext: `HealthLog/Stores/AppContainer.swift` is the single composition root.
  It owns ~70 injected dependencies (infra, repos, HealthKit infra, routing,
  foreground throttles, and the PHI-bearing store slice). For years its size
  carried a `swiftlint:disable file_length type_body_length`. This ADR captures
  the per-property rationale that used to live as inline doc-comments on the
  declarations, and the load-bearing structural decision (flat block + Mirror
  sweep) so the property block can stay terse without losing the "why".

This document is the canonical home for AppContainer composition rationale.
The property declarations in the source carry only terse one-liners now; the
substantive reasoning lives here. Reference: investigation
`.planning/v0157-features/INV-4-appcontainer.md`.

## The load-bearing decision — the flat PHI store block stays flat

Every PHI-bearing `Store` is a **direct, single-level stored property** of
`AppContainer`. This is deliberate and is NOT to be refactored into
sub-container types. Two independent `Mirror(reflecting: self).children` sweeps
depend on it:

1. **Production logout cascade** — `AppContainer+Logout.swift` builds
   `logoutClearables` by reflecting the container's direct stored properties and
   collecting every `any LogoutClearable`. `Mirror.children` is single-level: it
   does NOT descend into a property whose value is a sub-container. The moment a
   PHI store like `medicationsStore` becomes `meds.medicationsStore`, it
   disappears from the sweep and **silently stops being wiped on logout →
   cross-user PHI leak** (the B187 leak class the registry was built to kill).
   No compile error, no test failure — invisible until a security audit.

2. **`LogoutCompletenessTests`** — `storeTypedProperties` plus
   `registryClassifiesEveryStoreProperty` / `registryMatchesConformingStores`
   assert the flat sweep finds ≥30 stores and that the conforming set equals a
   hand-maintained name list keyed on the property label (e.g.
   `"medicationsStore"`). Nesting a store drops the count and removes its label,
   so the safety test can pass for the WRONG reason while the store is
   unprotected.

Consequence: **never nest a `LogoutClearable` PHI store.** Box-backed computed
stores (`coachAboutMeStore`, `miniCoachStore`, `coachConversationStore`) are the
only stores deliberately invisible to the Mirror sweep — and they each required
a bespoke `BoxBackedPHIStore` marker + their own completeness test
(`LogoutCompletenessTests+BoxBacked.swift`) plus an explicit clear call in the
cascade. Any new "Mirror can't see it" store owes the same treatment.

## How the body stays within lint budget

Every separable construction PHASE lives in a focused `make*` / `wire*` helper
extension (`+CoreInfra`, `+Repositories`, `+OutboxReplayFactory`,
`+MeasurementsMedications`, `+IntegrationStores`, `+Cycle`, `+ServerStats`,
`+LiveFlagsAttach`, `+LogoutHooks`, `+AIConsentGate`, `+Routing`,
`+Notifications`, `+FeatureFlags`, `+Foreground`, `+Wiring`, …). The primary
file holds the flat `let` declarations (Swift requires stored properties on the
type itself) plus the designated init that calls the factories in dependency
order. Inline wiring closures that previously bloated the init body were lifted
into `AppContainer+Wiring.swift` (the established pattern). Relocating the long
rationale doc-comments here let the property block shrink to terse one-liners.

## Init ordering / late-bound seams (must be preserved)

The init is one ordered sequence with deliberate ordering; sub-containers would
have to preserve it across type boundaries (interleaved, not layered):

- `metricInsightsRepo` is built AFTER `aiConsentStore` + `aiProviderStore` so it
  can capture the shared async consent gate (PB1 H1). A repo that depends on
  stores — a clean "repos here / stores there" split is impossible.
- The PR-snapshot box (`personalRecordsSnapshotBox`) is created early, captured
  by `MeasurementsStore`, then bound late once `serverStatsStores` exists.
- `earlyFeatureFlagsStore` is built ahead of position for MoodStore wiring, then
  assigned to `featureFlagsStore` later.
- `unauthorizedRef` is reset inside the cascade;
  `notificationClearOnLogoutHook` is defaulted in init and swapped by tests.
- `wireLogoutHooks` is deferred to the END of init because the cascade hooks
  weakly capture `self`, which must be fully initialised first.

## Per-property rationale (relocated from inline doc-comments)

### Core infrastructure
- `environment` — `internal(set) var` so onboarding's `reloadEnvironment()` can
  swap the baseURL after the user picks a custom server; mutated only on
  MainActor.
- `profileTimeZoneBox` — AUD-3 D-3 race-free bridge of the server-profile
  timezone to the off-main-actor `measurementsRepo`, so its
  `.dashboardSummary` write-invalidation day-key matches the day-key
  `DashboardStore` reads.

### Repositories
- `featureFlagsRepo` — F-1; see `featureFlagsStore`.
- `glp1LocalRepo` — T-5 GLP-1 detail stack: local-only SwiftData repo for
  titration ladder, side-effects logbook, pen inventory, injection-site picker.
  Parallel to the server-backed `medicationsRepo`; no replay-loop wiring until a
  future SB-T5-* endpoint adds round-tripping.
- `medicationTherapyLogRepo` — v0.12 SP3+SP4.
- `localRepo` — v0.11 W1 keystone: local-canonical SwiftData mirror for
  manual-entry Measurement / Mood / MedicationIntake rows. Additive + dormant in
  paired mode (read-union W2, Release door W5, adopt-on-pair upload W4).
  Recovery-wrapped like the GLP-1 + Outbox stores; synchronous launch tick.
- `disclaimerAckRepo` — v1.18.6 (DISC-02) one-time medical-disclaimer ack repo.
- `onboardingTourRepo` — #32 server-owned onboarding-tour / setup-completion.
- `measurementCategoriesRepo` — CAT-1 (`v1.4.30.1`): server-driven
  categorisation for HK-permission-picker grouping. Reads
  `GET /api/measurement-categories` with 10-min in-memory TTL; falls back to the
  hardcoded `CategoryAssignmentMap.bundledFallback` when offline.
- `moodTagCatalogRepo` — v0.14 structured mood-tag taxonomy
  (`GET /api/mood/tags`, daily-SWR).
- `passkeyRepo` / `withingsRepo` — v0.8.0 W6 settings-surface repos, lifted out
  of the Views.
- `whoopRepo` — v0.14.1 WHOOP (OAuth + BYO-key).
- `ouraRepo` / `polarRepo` / `fitbitRepo` / `nightscoutRepo` — v1.18.7
  web-parity (❌-7): Oura / Polar / Fitbit (server-OAuth) + Nightscout.
- `injectionSitePrefsRepo` — v0.11 (v1.8.5).
- `moduleGateRepo` — #30 (v1.18.0).
- `avatarRepo` — v0.8.0 W11 self-hosted avatar repo. Standalone (not in the C3
  bundle), same pinned `APIClient`.
- `sleepNightRepo` — v0.14.1 #124 per-night reconstructed sleep (hypnogram
  detail). Standalone read-only repo over the shared pinned `APIClient`.
- `serverStatsRepos` — V052-A7.
- `insightsLayoutRepo` — v0.8.0 W10 server-first Insights tile layout (order +
  visibility).
- `cycleRepo` — v0.14.8 cycle marathon: cycle data-layer repo. Built early so
  outbox-replay can drain the cycle kinds. Feature-flagged off (no UI).
- `coachAboutMeRepo` — W-B187 COACH-3 coach self-context + clarifying-question
  loop (adopt / dismiss / remember). Built early so outbox-replay can drain the
  adopt/dismiss kinds; shared by the Settings "About me" editor and the chat
  "remember this" action via `coachAboutMeStore`.
- `labsRepo` — v1.18.6 PHI labs repo, promoted to the composition root so the
  container-owned `labsStore` AND outbox-replay share ONE instance. Built early
  so replay can drain the labs write kinds (offline
  create/update/delete/restore survive a restart).
- `illnessRepo` — v1.18.6 PHI illness/condition-journal repo, promoted for the
  same reason as `labsRepo` (shared by `illnessStore` + outbox replay).
- `measurementReminderRepo` — v0.15 W-FRONTDOORS Vorsorge measurement-reminder
  repo, promoted so BOTH the Home next-due tile and the manage screen
  (`MeasurementRemindersScreen`) consult ONE app-wide store over a single
  SWR-deduped load (the screen previously built a view-local store).
- `bugReportRepo` — operator-gated bug-report surface (web `/bugreport` parity).

### HealthKit infra
- `healthKitUploader` — HK-batch uploader. Container-bound so tests can inject
  isolated.
- `healthKit` — iOS-only services (optional during tests/macOS).
- `backgroundSync` — coordinates HK background-deliveries + BGTaskScheduler.
  Public-readable so onboarding + re-entry path can trigger it.
- `healthKitDailyStatsSync` — V0.5.2 N4; see `AppContainer+HealthKitStats`.
- `healthKitHourlyHRSync` — W-HR-BUCKET-UPLOAD / GH #34 hourly heart-rate
  `stats:` bucket uploader. nil on non-HK builds / test hosts without HealthKit.
  Built in `AppContainer+HealthKitStats.makeHourlyHRSync`.

### Routing / notifications
- `appRouter` — tab + NavigationPath state holder for deep-link routing.
  Internal because `AuthenticatedShell.TabIdentifier` is internal.
- `deepLinks` — public entry point for all deep-link sources (`.onOpenURL`,
  UN-tap-handler, future universal links).
- `notifications` — APNs service. UIKit-delegate-adaptor forwards push callbacks
  via `AppDelegate.bridge`.
- `badgeRefreshCoalescer` — Y8: coalesces per-mutation badge refresh requests
  into a single in-flight Task. `MedicationsStore` fires `onIntakesDidChange`
  synchronously at five sites, several firing 2-3× per mark (optimistic patch →
  server confirm → invalidate). The coalescer cancels any pending task and
  replaces it so only the last winner runs; iOS coalesces identical badge values
  internally so no drift risk. A small reference box so the wiring closure can
  mutate the pending-Task slot without capturing `self`.
- `notificationClearOnLogoutHook` — LOGOUT-NOTIF side-effect seam for clearing
  delivered + pending notifications + the app-icon badge on sign-out. Defaults
  (in init) to `NotificationService.clearAllNotificationsOnLogout()`; the logout
  cascade invokes it unconditionally (local, network-independent). A closure
  (not a direct call) so `LogoutCompletenessTests` can swap a spy. No-op on
  non-UserNotifications platforms.

### Foreground throttles
- `dailyStatsForegroundThrottle` — W8-A1 self-throttle for
  `refreshHealthKitDailyStatsForToday`. Both `RootView` and `DashboardScreen`
  historically fired the foreground HK-stats sync on every `.active`, running it
  twice concurrently against the ≤300ms budget. Coalesces non-forced calls
  within 10s; pull-to-refresh passes `force: true`.
- `foregroundNetworkThrottle` — W8-8 (entry point in `+Foreground`).
- `foregroundCheapThrottle` — A7-M1 coarse coalescer for the three "cheap but
  unconditional" foreground members in `RootView.handle(scenePhase:)`:
  HK-readiness re-query, App-Badge recompute, mood-reminder re-arm. Each is
  cheap, but they ran on every `.active` — including 2-second app-switcher
  bounces. Non-forced call within the window is suppressed.
- `swrCacheSweepThrottle` — AUD-8 H-1: coalesces the foreground SWR-cache
  maintenance sweep (age-sweep + row-count cap) to at most once an hour, so a
  power user's persistent cache stays bounded even with Background-App-Refresh
  disabled (the BGTask sweep alone never fires in that case).

### Stores (PHI-bearing slice — these stay flat for the Mirror sweep)
- `syncModeStore` — `.standalone` (local-only) vs `.paired` (server-backed). Set
  during onboarding, flippable via Settings → "Mit Server verbinden".
- `backendAvailability` — R4 §3.1 groundwork: single capability surface folding
  sync-mode + auth + reachability into one observable that views/stores consult
  instead of hard-reading `SyncModeStore.isStandalone`. Paired-path invariant:
  every flag returns `true` on a normal paired+authed install (zero behaviour
  change). The seam v0.11 standalone hangs off.
- `insightsLayoutStore` — v0.8.0 W10 server-first Insights tile layout store.
- `deliveryPreferencesStore` — v0.9.0 RA3 unified per-medication delivery
  preferences (Live Activity + AlarmKit critical alarm) with a "Dieses Gerät /
  Alle Geräte" scope per channel. Server-default layer is the
  `NoServerDeliveryDefaults` stub today (purely device-local; SB-LA-1 / SB-AK-1
  light up "Alle Geräte"). Read/written by the medication edit sheet + consumed
  by the Live-Activity + AlarmKit reconcile gates.
- `medicationLiveActivityController` — v0.8.4 WWIDGET-1: owns the medication Live
  Activity lifecycle (start/update/end of the Lock-Screen + Dynamic-Island dose
  countdown). Driven from the medications/intakes reconcile path so the soonest
  due dose surfaces a glanceable "Genommen" button. The `NotificationService` is
  the push-token sink so a later server contract can drive Live Activities via
  APNs.
- `widgetSnapshotWriter` — v0.8.4 WWIDGET-2: writes the App Group widget snapshot
  + reloads the Home / Lock-Screen widget timelines on every intake change. Held
  so the logout path can reset the snapshot to its placeholder.
- `spotlightCoordinator` — W-B187 QOL-2: drives the CoreSpotlight index off the
  medications / available-kinds settle hooks (off the main actor). Held so the
  logout path can tear the whole index down (no med name survives sign-out).
- `watchSession` — v0.12 P2: owns the iPhone end of the watchOS companion's
  WatchConnectivity session (pushes the glanceable snapshot, receives med-intake
  / mood actions and funnels them onto the live stores).
- `cycleGate` / `cycleStore` — v0.14.8 cycle marathon: gate + store for the
  (not-yet-built) cycle surfaces. Both dormant behind
  `FeatureFlag.cycleTracking` (default OFF).
- `moodTagCatalogStore` — v0.14 structured mood-tag catalog store for the
  Daylio-style picker.
- `moodTagManagementStore` — v1.13.0 management store for the "Stimmungs-Tags
  verwalten" screen (effective + hidden read, custom-tag CRUD, catalogue
  hide/show).
- `moodHealthSyncStore` — v0.10.0 W-Mood-B: owns the "Mit Apple Health
  synchronisieren" toggle + the State-of-Mind import lifecycle.
- `insightsPrefetch` — W3 (#22) daily cache-warmer.
- `measurementRemindersStore` — v0.15 W-FRONTDOORS app-wide Vorsorge reminder
  store. One instance backs both the Home next-due tile and
  `MeasurementRemindersScreen`; SWR dedupes the load. Cleared on logout (PHI).
- `labsStore` — v1.18.6 PHI app-wide labs store (was view-local `@State` built by
  `LabsScreenFactory`). Promoted to a container singleton so its in-memory
  lab-result + biomarker PHI joins the logout cascade (`clearOnLogout`) and
  SWR-deduped loads survive navigation. One instance backs `LabsScreen` + the
  biomarker catalog.
- `illnessStore` — v1.18.6 PHI app-wide illness/condition-journal store (was
  view-local `@State` built by `IllnessScreenFactory`). Promoted so its
  in-memory episode + day-log PHI is purged on logout (`clearOnLogout`).
- `aiConsentStore` — AI-consent gate (S7 / QA3 BLOCKER 2). Apple Guideline
  5.1.2(i).
- `trendsOverlayStore` — v0.6.2.3 F2-CHARTLAG: hoisted from `ChartsScreen` so the
  user's metric-toggle + range selection survives navigation pop / tab-switch /
  view re-mount. Previously per-view `@State`, which dropped selection every
  unmount. One instance per container; `selectedMetrics`, `range`, and the loaded
  `normalisedSeries` persist for the session.
- `doctorReportStore` — server-rendered.
- `localDoctorReportStore` — T-7 local.
- `disclaimerAckStore` — v1.18.6 (DISC-02) app-wide one-time medical-disclaimer
  ack. Drives the first-run ack gate AND suppresses the scattered per-screen
  informational disclaimers once acknowledged.
- `onboardingTourStore` — #32 server-owned onboarding-tour / setup-completion
  state. Reconciles the local routing flag against `onboardingTourCompleted` so
  progress survives reinstall + syncs across devices.
- `diabetesStore` — v1.18.6 per-user diabetes opt-in (ADA glucose bands,
  server-resolved).
- `injectionSitePrefsStore` — v0.11 (v1.8.5).
- `moduleGate` — #30 (v1.18.0) server-authoritative per-user feature-module gate.
  Single source of truth for which optional modules surface. CycleGate consults
  it.
- `coachNudgeStore` — v1.18.6 (CCH-03) server-authoritative unread signal driving
  the discreet Coach nudge dot on the floating button + the More-tab Coach row.
- `coachCadenceSuggestionsStore` — W-COACH-CADENCE (#30 v1.18.1) proactive coach
  cadence-suggestion cards on the Insights overview. Opt-in (default ON,
  unobtrusive), coach-module + online gated; accept creates the reminder
  server-side and re-lists the native reminders. Cleared on logout (the
  rationale may reference the user's data — never bleeds across accounts).
- `passkeyManagementStore` / `withingsIntegrationStore` — v0.8.0 W6
  settings-surface stores wrapping the passkey / Withings repos so the screens go
  through Store→Repo, not in-View API.
- `whoopIntegrationStore` — v0.14.1.
- `ouraIntegrationStore` / `polarIntegrationStore` / `fitbitIntegrationStore` /
  `nightscoutIntegrationStore` — v1.18.7 web-parity (❌-7) provider-distinct
  `@Observable` stores.
- `avatarStore` — v0.8.0 W11 self-hosted avatar display + upload store.
- `hkReadinessStore` — HK-readiness self-check store (F7 / v0.4.1).
- `featureFlagsStore` — F-1 / R5 + D-1: flag cache + on-device assistant services
  (see `AppContainer+FeatureFlags`).
- `serverStatsStores` — V052-A7.
- `undoCoordinator` — shared undo affordance: surfaces the transient
  `Rückgängig`-pill for destructive store paths (measurement / mood deletes,
  medication archive). At the composition root so all three stores talk to one
  toast slot the shell renders.
- `celebrationCoordinator` — v0.5.5.6 RECONCILE-CELEBRATE: shared personal-record
  celebration slot. `MeasurementsStore` publishes here on a commit that beats the
  prior bucket leader; the SwiftUI root overlays `CelebrationOverlay` whenever
  `current` is non-nil.
- `loincReviewRegistry` — v0.6.0.5 physician-review sign-off for the LOINC
  mappings the H.1 table flags `physicianReviewPending`. Surfaced via
  `SettingsLOINCReviewScreen`. State persists in UserDefaults; the FHIR-export
  screen disclaims only the kinds still missing sign-off.
- `liveHealthKitTodayStore` — v0.6.2.x bug-c10-ios-direct: HK-direct today step
  total store. Dashboard tile + chart-detail today-segment read from here so
  freshly-walked steps render even when the server `stats:` row is frozen
  (insert-only batch route).
- `unauthorizedRef` — accessed from `AppContainer+Logout.swift`; needs internal
  visibility.
