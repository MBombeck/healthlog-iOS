import Foundation
import SwiftUI

/// Zentrale Route-State-Holder für Tab-Selection + per-Tab-NavigationPath.
///
/// Vorher hat `AuthenticatedShell` `selectedTab` lokal gehalten — Deep Links
/// hätten den Tab nicht von außen ändern können. Mit diesem Observable
/// liest die Shell den Tab aus dem Environment, und `DeepLinkRouter.handle(_:)`
/// flippt ihn über `apply(_:)` plus pusht den passenden NavigationPath-Eintrag.
///
/// Cold-Start-Pattern: wenn `apply(_:)` vor erfolgreichem Auth-Bootstrap
/// aufgerufen wird (Tap auf Push-Banner während App noch nicht ready), parkt
/// die Route in `pendingRoute`. `RootView` konsumiert sie nach dem
/// `phaseKey == "auth"`-Switch.
@MainActor
@Observable
final class AppRouter {
    var selectedTab: AuthenticatedShell.TabIdentifier = .home
    var homePath: NavigationPath = .init()
    var medsPath: NavigationPath = .init()
    var insightsPath: NavigationPath = .init()
    var morePath: NavigationPath = .init()

    /// Geparkte Route für Cold-Start-from-Tap. Konsumiert + geleert von
    /// `consumePendingRoute()` sobald der Auth-Bootstrap fertig ist.
    private(set) var pendingRoute: DeepLinkRoute?

    /// v0.5.4.3 HP5 — transient flag observed by `AuthenticatedShell` to
    /// surface `MoodQuickEntrySheet` when a mood-reminder action handler
    /// signals "open the quick-capture surface" (taps on the body of a
    /// `MOOD_REMINDER` push, or the `mood.log.now` action). Modeled as
    /// a counter rather than `Bool` so back-to-back triggers always re-
    /// present the sheet even if the shell hasn't yet processed the
    /// previous edge — matches the haptic-pulse counter pattern in
    /// `AuthenticatedShell.captureTapPulse`.
    ///
    /// Counter rather than route because the sheet is sheet-state, not
    /// navigation-state — it doesn't push onto a `NavigationPath` and a
    /// `DeepLinkRoute` would mix mental models. The shell flips the tab
    /// to `.home` first (so the sheet covers a recognisable surface)
    /// then presents the sheet.
    private(set) var moodQuickEntryRequestCount: Int = 0

    /// v0.14.x Q — transient counter observed by `AuthenticatedShell` to
    /// surface the medication quick-intake confirm sheet. Driven by the
    /// Home-Screen Quick Action "Log an intake" hand-off (consumed in
    /// `RootView` from a `CaptureRequestStore` marker). Counter rather than
    /// `Bool` so back-to-back invocations always re-present the sheet even if
    /// the shell hasn't processed the previous edge — same pattern as
    /// `moodQuickEntryRequestCount`. The sheet is sheet-state (not
    /// navigation-state) so it doesn't push onto any `NavigationPath`.
    private(set) var medicationQuickIntakeRequestCount: Int = 0

    /// **POLISH-COACH (v0.5.5.6)** — transient counter observed by
    /// `InsightsScreen` so the `.coach` deep-link surfaces the new
    /// `AskCoachSheet` instead of silently landing on Insights with no
    /// further action. Mirrors `moodQuickEntryRequestCount` — the sheet
    /// is sheet-state (not navigation-state), so it doesn't push onto
    /// any `NavigationPath`. Counter rather than `Bool` so back-to-back
    /// invocations always re-present the sheet even if Insights hasn't
    /// processed the previous edge yet.
    private(set) var askCoachRequestCount: Int = 0

    /// #34 — re-tap-to-root for the Insights tab. The Insights container drives
    /// its surface with a LOCAL `@State selection` (not a router `NavigationPath`
    /// like `MoreScreen`), so re-tapping the active Insights tab can't be reset
    /// by clearing a path here. Instead the shell bumps this counter on an
    /// Insights re-tap; `InsightsContainerScreen` observes it and resets to
    /// `selection = .overview` (pager index 0). Counter (not `Bool`) so
    /// back-to-back re-taps always re-fire the reset. Standard iOS behaviour:
    /// tapping the already-selected tab returns it to its root.
    private(set) var insightsRootRequestCount: Int = 0

    /// **v0.12 W0-1/W0-3** — the metric slug a `.insights(metric:)` deep link
    /// wants the Insights pager to scroll to. The Insights container drives its
    /// surface with a LOCAL `@State selection` (the swipe pager — NOT a router
    /// `NavigationPath`), so a deep link cannot push a typed route onto a stack
    /// the way Meds/More do. Instead the router parks the requested slug here +
    /// bumps `insightsMetricRequestCount`; `InsightsContainerScreen` observes the
    /// counter and maps the slug onto `selection = .metric(kind)` (or a special
    /// page). This replaces the dead `InsightsDetailRoute` ghost type that was
    /// appended to `insightsPath` and consumed nowhere (W0-3). `nil` (with a
    /// bumped counter) means "Insights root / Übersicht".
    private(set) var pendingInsightsMetricSlug: String?

    /// Counter paired with `pendingInsightsMetricSlug` so back-to-back deep links
    /// to the same metric always re-fire the selection even if the container
    /// hasn't processed the previous edge yet (same pattern as the other
    /// request counters above).
    private(set) var insightsMetricRequestCount: Int = 0

    /// v0.12 W0-fix (review H1) — high-water mark of the last
    /// `insightsMetricRequestCount` the container has consumed. Makes the parked
    /// slug **one-shot**: `consumePendingInsightsMetric()` returns a slug exactly
    /// once per bump, so a bare container re-appear (tab switch / scenePhase /
    /// parent invalidation) with NO new deep link does not re-snap the pager back
    /// to the last deep-linked metric. Lives on the router (not container `@State`)
    /// so it survives container re-creation.
    private var lastConsumedInsightsCount: Int = 0

    /// b182 W-B182-INVITE (GH #16) — the server invite token (`hlv_<64 hex>`)
    /// parked from an `.invite` deep link (web QR / universal link / custom
    /// scheme). **AUTH-AGNOSTIC, unlike `pendingRoute`:** the normal pending-route
    /// mechanism only fires *after* `.authenticated` (`RootView` consumes it post-
    /// auth), but an invite must surface *before* auth — it drives the
    /// unauthenticated onboarding registration flow. So `.invite` is parked here
    /// regardless of auth phase, and `OnboardingFlow` consumes it one-shot.
    ///
    /// Sensitive secret — never logged. One-shot via `consumePendingInviteToken()`.
    private(set) var pendingInviteToken: String?

    /// W-INVITE-DEEPLINK (#16) — transient counter bumped when an invite link is
    /// opened while the user is ALREADY signed in. An invite drives *registration*
    /// (creating a new account); it can't be applied to a session that already has
    /// one, so rather than silently swallow the tap, `AuthenticatedShell` observes
    /// this counter and surfaces a calm, non-destructive notice ("an invite can't
    /// be applied to an account you're already signed into"). Counter (not `Bool`)
    /// so back-to-back invite taps always re-present even before the shell
    /// processes the previous edge — same pattern as the other request counters.
    /// The token itself is NOT parked in this case (it would dead-end / risk a
    /// scary re-register), so nothing sensitive is held; only the fact-of-tap.
    private(set) var inviteWhileSignedInNoticeCount: Int = 0

    /// v0.15 W-FRONTDOORS — the metric kind a "jetzt messen" Vorsorge action
    /// wants the `MeasureSheetView` to open prefilled to. Parked here (with a
    /// bumped `measurePrefillRequestCount`) by the Home Vorsorge tile;
    /// `AuthenticatedShell` observes the counter, flips to `.home`, and presents
    /// the measure sheet seeded to this kind. `nil` means "no prefill" (the
    /// central Erfassen path). Sheet-state, not nav-state — so it doesn't push
    /// onto any `NavigationPath`.
    private(set) var pendingMeasurePrefillKind: MetricKind?

    /// Counter paired with `pendingMeasurePrefillKind` so back-to-back "jetzt
    /// messen" taps always re-present the sheet even if the shell hasn't
    /// processed the previous edge (same pattern as the other request counters).
    private(set) var measurePrefillRequestCount: Int = 0

    init() {}

    /// v0.15 W-FRONTDOORS — request the prefilled measure sheet for `kind`.
    /// Flips the tab to `.home` first so the sheet covers a recognisable
    /// surface, then bumps the counter the shell observes. Mirrors
    /// ``requestMoodQuickEntry()``.
    func requestMeasure(prefill kind: MetricKind) {
        selectedTab = .home
        homePath = .init()
        pendingMeasurePrefillKind = kind
        measurePrefillRequestCount &+= 1
    }

    /// Consume the parked measure-prefill kind exactly once (clear on read).
    /// `AuthenticatedShell` reads it when its `measurePrefillRequestCount`
    /// observer fires; a re-appear without a fresh request returns `nil`.
    func consumeMeasurePrefillKind() -> MetricKind? {
        let kind = pendingMeasurePrefillKind
        pendingMeasurePrefillKind = nil
        return kind
    }

    /// b182 W-B182-INVITE — consume the parked invite token exactly once (clear
    /// on read), mirroring the other one-shot consume patterns. `OnboardingFlow`
    /// reads it to auto-open the prefilled `RegistrationSheet`; a second read
    /// returns `nil` so a re-appear (scenePhase / tab churn) doesn't re-trigger
    /// the invite flow.
    func consumePendingInviteToken() -> String? {
        guard let token = pendingInviteToken else { return nil }
        pendingInviteToken = nil
        return token
    }

    /// v0.12 W0-fix (review H1) — consume the parked Insights metric slug exactly
    /// once per `insightsMetricRequestCount` bump. Returns the OUTER optional
    /// `.none` when there is no fresh (unconsumed) request — the caller must then
    /// do nothing (this is what stops the stale re-snap on every `onAppear`). When
    /// a fresh request exists, returns `.some(slug)` where the INNER `slug` may be
    /// `nil` (= "Übersicht / root"). Clears the parked slug on consume.
    func consumePendingInsightsMetric() -> String?? {
        guard insightsMetricRequestCount > lastConsumedInsightsCount else { return .none }
        lastConsumedInsightsCount = insightsMetricRequestCount
        let slug = pendingInsightsMetricSlug
        pendingInsightsMetricSlug = nil
        return .some(slug)
    }

    /// v0.13.1 IC — unify the tile tap. Lands the operator IN the Insights tab
    /// on `kind`'s metric page via the existing `.insights(metric:)` deep link
    /// (switches `selectedTab` → `.insights`, parks the slug, bumps the request
    /// counter so `InsightsContainerScreen` selects the pager page). This is the
    /// fix for the operator's "tapping a Dashboard tile opens a separate page,
    /// not the Insights metric page" report: previously the Dashboard PUSHED the
    /// same `InsightsMetricScreen` onto the Home `NavigationStack`, so it was a
    /// second navigation INSTANCE of the screen on the wrong tab. The deep link is
    /// availability-gated downstream (`tryApplyStagedMetric`), so it relies on
    /// the IC availability fix to reliably land on the metric rather than the
    /// overview.
    /// **Parity 1.10 — the dead-tap safety net.**
    ///
    /// The `guard` used to `return` after a log line. The doc above still says
    /// "none today for charted kinds"; that has not been true for a while —
    /// four kinds ship a dashboard tile and no Insights slug, so their tile
    /// looked tappable and did nothing at all, with the only evidence in a log
    /// nobody reads. Silence is the worst possible outcome here: the operator
    /// cannot tell a missing slug from a stuck app.
    ///
    /// The fallback lands on `MeasurementListScreen(kind:)` — the per-kind
    /// values table on the Mehr stack, the same screen the manual path
    /// (Mehr → Messwerte → row) reaches. It is a step sideways from the
    /// intended Insights page, not a substitute, but it shows the operator
    /// their data for that metric instead of nothing.
    ///
    /// The four slugs get wired properly in a later build; this net exists so
    /// that fixing them is an improvement rather than a prerequisite, and so a
    /// future kind added without a slug degrades visibly instead of silently.
    func selectInsightsMetric(_ kind: MetricKind) {
        // b241 Fix 1 — mood is NOT a `Measurement`: its 483 rows are `MoodEntry`s
        // served only by `/api/mood-entries` (`MoodStore`/`MoodRepository`), never
        // by `/api/measurements`. Routing a mood tile tap through the slug-less
        // fallback landed the operator on `MeasurementListScreen(kind: .mood)`,
        // which queries `/api/measurements` and is therefore ALWAYS empty
        // ("Noch keine Messungen") even though the mood history is full. Route the
        // tap to the dedicated Mood Insights special page instead — the same
        // navigable surface (`InsightsMoodPage`) the wellness-sheet mood
        // contributor reaches, which reads `MoodStore.entries` (the real data).
        if kind == .mood {
            selectInsightsSpecial(.mood)
            return
        }
        guard let slug = InsightsTabSlug.slug(forKind: kind) else {
            HLLog.ui.notice(
                "selectInsightsMetric: no Insights slug for \(kind.rawValue) — falling back to the values table"
            )
            showMeasurementList(kind)
            return
        }
        applyImmediate(.insights(metric: slug))
    }

    /// Parity 1.10 — pushes the per-kind values table onto the Mehr stack.
    /// Mirrors ``requestSettingsAssistant()``'s stack-root-then-push shape.
    func showMeasurementList(_ kind: MetricKind) {
        selectedTab = .more
        morePath = .init()
        morePath.append(MeasurementListRoute(kind: kind))
    }

    /// v0.14.3 F3 — deep-nav into one of the three composite **special** Insights
    /// pages (mood / medications / workouts). Mirrors `selectInsightsMetric` but
    /// for pages that are NOT a chartable `MetricKind`: the wellness-score detail
    /// sheet's Stimmung contributor routes here so it lands on the navigable Mood
    /// Insights page (tab strip + swipe + back) instead of dead-ending. Parks the
    /// special page's layout slug; `InsightsContainerScreen` resolves it onto the
    /// pager via `InsightsSpecialPage.page(forSlug:)`.
    func selectInsightsSpecial(_ page: InsightsSpecialPage) {
        applyImmediate(.insights(metric: page.slug))
    }

    /// #34 — invoked by the shell when the operator taps the ALREADY-active
    /// Insights tab. Pops the shared Insights stack to root and bumps the
    /// counter so the container resets its pager to Übersicht (index 0).
    func requestInsightsRoot() {
        insightsPath = .init()
        insightsRootRequestCount &+= 1
    }

    /// v0.15.7 W-RHYTHM-FRONTDOOR — switch to the Insights tab AND reset its
    /// pager to the Übersicht overview, where the device-health-notifications
    /// (ECG/AFib rhythm-events) card lives. Unlike `requestInsightsRoot` (which
    /// only resets the already-active tab), this also flips `selectedTab`, so a
    /// Home front-door tile can land the operator straight on the overview that
    /// hosts the rhythm-events card. The card self-suppresses when empty, so the
    /// tile only routes here when there ARE events — there is no per-card slug to
    /// deep-link, the overview is the canonical home of the card.
    func requestInsightsOverview() {
        selectedTab = .insights
        insightsPath = .init()
        insightsRootRequestCount &+= 1
    }

    /// Wendet eine Route auf den Router an. Wenn `isAuthenticated == false`,
    /// wird die Route in `pendingRoute` geparkt; sonst direkt angewendet.
    func apply(_ route: DeepLinkRoute, isAuthenticated: Bool) {
        // b182 W-B182-INVITE / W-INVITE-DEEPLINK (#16) — `.invite` drives the
        // *unauthenticated* onboarding registration flow, so it must surface
        // BEFORE auth (unlike `pendingRoute`, which only fires post-auth). Branch
        // on the live auth phase:
        //   • Unauthenticated → park the token; `OnboardingFlow` consumes it
        //     one-shot into the prefilled registration sheet.
        //   • Already signed in → an invite creates a NEW account; it cannot be
        //     applied to an existing session. Rather than silently drop the tap,
        //     bump a notice counter the shell surfaces as a calm, non-destructive
        //     message. We deliberately do NOT park the token here — there's no
        //     register to feed it to, and holding a registration secret on a
        //     signed-in session is pointless + risks a scary re-register prompt.
        if case let .invite(token) = route {
            if isAuthenticated {
                inviteWhileSignedInNoticeCount &+= 1
            } else {
                pendingInviteToken = token
            }
            return
        }
        guard isAuthenticated else {
            pendingRoute = route
            return
        }
        applyImmediate(route)
    }

    /// Konsumiert eine geparkte Route. Aufgerufen von `RootView` nach dem
    /// Auth-Phase-Switch auf `.authenticated`. Idempotent — nach Konsum nil.
    func consumePendingRoute() {
        guard let route = pendingRoute else { return }
        pendingRoute = nil
        applyImmediate(route)
    }

    /// v0.5.4.3 HP5 — requests that `AuthenticatedShell` surface
    /// `MoodQuickEntrySheet`. Called by the mood-reminder action handler
    /// (`mood.log.now`) and by body-taps on `MOOD_REMINDER` pushes. Flips
    /// the tab back to `.home` first so the sheet covers a recognisable
    /// surface — the user opened a quick-capture intent, not a tab
    /// navigation. Increments a counter so back-to-back invocations
    /// re-present the sheet even before the shell's `.onChange` has
    /// resolved the previous edge.
    func requestMoodQuickEntry() {
        selectedTab = .home
        homePath = .init()
        moodQuickEntryRequestCount &+= 1
    }

    /// **v0.8.4 WWIDGET-3** — requests that `AuthenticatedShell` surface the
    /// capture picker. Called when the app foregrounds with a pending
    /// "Erfassen" control marker (`OpenCaptureIntent` → `CaptureRequestStore`
    /// → `RootView` consume). Reuses the *same* mechanism a tap on the centre
    /// "Erfassen" action slot uses: flipping `selectedTab` to `.measure` makes
    /// the shell's existing `onChange(of: selectedTab)` present the capture
    /// sheet and snap the tab back, so there's one capture-entry code path,
    /// not two. No counter needed — the tab-flip + snap-back is itself
    /// edge-triggered by the shell.
    func requestCapture() {
        selectedTab = .measure
    }

    /// v0.14.x Q — requests that `AuthenticatedShell` surface the medication
    /// quick-intake confirm sheet. Called when the app foregrounds with a
    /// pending `.medication` Quick-Action marker (Home-Screen long-press →
    /// "Log an intake" → `CaptureRequestStore` → `RootView` consume). Flips the
    /// tab back to `.home` first so the sheet covers a recognisable surface (the
    /// user invoked a quick-capture intent, not a tab navigation), then bumps
    /// the counter the shell observes. Mirrors `requestMoodQuickEntry()`.
    func requestMedicationQuickIntake() {
        selectedTab = .home
        homePath = .init()
        medicationQuickIntakeRequestCount &+= 1
    }

    /// v0.14.1 — lands the operator on Settings → Assistant ("KI"-Hub), where
    /// the server AI provider / BYO key is configured. Called from the Coach's
    /// "External AI needs a server provider" surface (`CoachSourceChoiceView`)
    /// so tapping "Externe KI" without a provider routes to setup instead of
    /// silently bouncing. Pushes `.root` THEN `.assistant` so the back stack is
    /// Mehr → Settings → Assistant (mirrors the `.settingsNotifications` route).
    func requestSettingsAssistant() {
        selectedTab = .more
        morePath = .init()
        morePath.append(SettingsRoute.root)
        morePath.append(SettingsRoute.assistant)
    }

    /// Web-parity `TodayHero` — lands the operator on Settings → Integrations,
    /// where a broken sync is reconnected. Called by the daily-digest rail's
    /// `sync.reconnect` action (web href `/settings/integrations`). Pushes
    /// `.root` THEN `.integrations` so the back stack is Mehr → Settings →
    /// Integrationen (mirrors ``requestSettingsAssistant()``).
    func requestSettingsIntegrations() {
        selectedTab = .more
        morePath = .init()
        morePath.append(SettingsRoute.root)
        morePath.append(SettingsRoute.integrations)
    }

    /// CU-37 — lands the operator on Settings → Integrationen →
    /// Apple-Health-Import, the ONE path by which an ECG recording can reach
    /// HealthLog today (`POST /api/import/apple-health-export`; there is no JSON
    /// ingest route and no HealthKit live-sync — GH #74). Called from the ECG
    /// surface's empty state, which would otherwise name a destination without
    /// being able to reach it. Pushes `.root` THEN `.integrations` THEN
    /// `.appleHealthImport` so the back stack retraces the real IA
    /// (Mehr → Einstellungen → Integrationen → Apple-Health-Import).
    func requestAppleHealthImport() {
        selectedTab = .more
        morePath = .init()
        morePath.append(SettingsRoute.root)
        morePath.append(SettingsRoute.integrations)
        morePath.append(SettingsRoute.appleHealthImport)
    }

    /// GH #74 — lands the operator on Settings → Integrationen → Apple Health,
    /// the screen that carries the ECG upload switch. Called from the ECG empty
    /// state when the switch is off: the honest answer to "why is this empty"
    /// is "the upload is off", and the honest form of that answer is the way to
    /// the switch, not a sentence about it. Pushes `.root` THEN `.integrations`
    /// THEN `.appleHealthDetail` so the back stack retraces the real IA.
    func requestAppleHealthSettings() {
        selectedTab = .more
        morePath = .init()
        morePath.append(SettingsRoute.root)
        morePath.append(SettingsRoute.integrations)
        morePath.append(SettingsRoute.appleHealthDetail)
    }

    /// #42 (v1.27.6) — lands the operator on the mental-health check-in surface
    /// (`MentalWellbeingScreen`). Called when a **screening reminder**
    /// (`PHQ9_SCORE` / `GAD7_SCORE` / `WHO5_SCORE`) is actioned: a screening sum
    /// score is NOT hand-entered on a numeric capture form, so the reminder's
    /// action starts the corresponding self-check instead. Flips to the More tab
    /// and pushes the `MentalWellbeingRoute` onto `morePath` (resolved by a
    /// `.navigationDestination(for:)` in `MoreScreen`), mirroring
    /// `requestSettingsAssistant()`. We route to the check-in *surface* (the
    /// instrument chooser) rather than auto-starting a specific instrument — the
    /// screen/store internals are owned by the parallel WHO-5 wave.
    func requestMentalWellbeingCheckIn() {
        selectedTab = .more
        morePath = .init()
        morePath.append(MentalWellbeingRoute())
    }

    /// W0-fix (review M1) — pure mapping from a med deep-link route to its typed
    /// detail payload, so the `.history` focus carried by a `…/history` reminder
    /// is unit-testable (the `NavigationPath` it is appended to is not
    /// introspectable). A regression that dropped `.history` here would be caught
    /// by `AppRouterNavigationTests`. Returns `nil` for non-medication routes.
    static func medicationDetailRoute(for route: DeepLinkRoute) -> MedicationDetailRoute? {
        switch route {
        case let .medication(id): MedicationDetailRoute(id: id)
        case let .medicationHistory(id): MedicationDetailRoute(id: id, focus: .history)
        default: nil
        }
    }

    private func applyImmediate(_ route: DeepLinkRoute) {
        switch route {
        case .dashboard:
            selectedTab = .home
            homePath = .init()
        case .coach:
            // POLISH-COACH (v0.5.5.6) — flip to Insights and pulse the
            // `askCoachRequestCount` counter so `InsightsScreen`
            // presents `AskCoachSheet`. Counter (not route) because
            // the sheet is sheet-state, not nav-state — it doesn't
            // push onto a `NavigationPath`, and back-to-back deep-links
            // re-present the sheet even before the previous edge is
            // consumed. The Insights tab is the host because Coach
            // belongs in the analytics surface, not Dashboard.
            selectedTab = .insights
            insightsPath = .init()
            askCoachRequestCount &+= 1
        case let .insights(metric):
            // v0.12 W0-1/W0-3 — Insights is a swipe pager driven by the
            // container's local `selection`, not a `NavigationPath`. Park the
            // requested slug + bump the counter; `InsightsContainerScreen`
            // resolves the slug onto its `selection`. Clearing `insightsPath`
            // also pops any pushed metric screen so the pager surface is shown.
            selectedTab = .insights
            insightsPath = .init()
            pendingInsightsMetricSlug = metric
            insightsMetricRequestCount &+= 1
        case .medications:
            // v0.12 W0-2 — the med-reminder no-id fallback. Lands the operator
            // on the Meds tab list root rather than teleporting to Dashboard
            // (the old `.unknown` behaviour). No detail to push without an id.
            selectedTab = .meds
            medsPath = .init()
        case .medication, .medicationHistory:
            // v0.3.x: kein dedizierter History-Screen — wir landen im Detail
            // mit History-Tab-Hint. Volle Web-Embed-History bleibt v0.3.x+.
            // W0-fix (review M1): the typed payload (incl. `.history` focus) is
            // built by the pure, unit-testable `medicationDetailRoute(for:)` so a
            // regression dropping the focus is caught by a test (NavigationPath
            // payloads themselves aren't introspectable).
            if let detail = Self.medicationDetailRoute(for: route) {
                selectedTab = .meds
                medsPath = .init()
                medsPath.append(detail)
            }
        case let .personalRecord(id):
            selectedTab = .more
            morePath = .init()
            morePath.append(PersonalRecordRoute(id: id))
        case .settingsNotifications:
            selectedTab = .more
            morePath = .init()
            morePath.append(SettingsRoute.root)
            morePath.append(SettingsRoute.notifications)
        case .mood:
            // v0.10.0 W10 — `healthlog://mood` (the systemSmall mood widget's
            // whole-tile tap) reuses the same central-CTA quick-entry path the
            // `mood.log.now` reminder action uses — no parallel surface.
            requestMoodQuickEntry()
        case .mentalWellbeing:
            // #42 (v1.27.6) — a screening reminder (PHQ9/GAD7/WHO5) opens the
            // mental-health check-in surface, never a numeric capture form.
            // Reuses the same push path as the in-app reminder-card action, so a
            // future server-supplied `healthlog://check-in` deep-link on a
            // screening push lands on the identical surface.
            requestMentalWellbeingCheckIn()
        case let .invite(token):
            // b182 W-B182-INVITE — `apply(_:isAuthenticated:)` short-circuits
            // `.invite` before it reaches here, so this branch is only hit by a
            // direct `applyImmediate` (e.g. tests / future callers). Park the
            // token; the onboarding flow consumes it. No nav side-effect — the
            // invite surfaces in the unauthenticated onboarding shell, not a tab.
            pendingInviteToken = token
        case let .unknown(url):
            // b182 W-B182-INVITE — token-safe logging. A malformed invite link
            // resolves to `.unknown` and its query could carry a partial secret,
            // so we log the host/path only, never `url.absoluteString`.
            // M-7: host + path are sanitized, non-sensitive values → `.public`.
            // swiftlint:disable:next hllog_public_privacy_interpolation
            HLLog.notifications.warning(
                "Unbekannte Deep-Link-Route — fallback auf Dashboard. Host=\(url.host ?? "", privacy: .public) Pfad=\(url.path, privacy: .public)"
            )
            selectedTab = .home
            homePath = .init()
        }
    }
}

// MARK: - NavigationPath payload types

// v0.12 W0-3 — the `InsightsDetailRoute` ghost type was removed. It was
// appended to `insightsPath` and consumed by no `navigationDestination`, and
// its doc-comment described a soft-scroll contract that was never built. The
// Insights tab is a swipe pager driven by the container's local `selection`,
// so a `.insights(metric:)` deep link now routes through
// `AppRouter.pendingInsightsMetricSlug` (mapped onto `selection` in
// `InsightsContainerScreen`) rather than a `NavigationPath` push.

/// v0.12 W0-1 — typed Meds-stack deep-link payload (id + focus). `public` so
/// `Focus` can be a default-argument value in the
/// `public MedicationDetailScreen.init(...focus:)` signature.
public struct MedicationDetailRoute: Hashable {
    /// Where a med-detail deep link should land the operator.
    public enum Focus: String, Hashable {
        case overview
        case history
        /// M1 — an in-app compliance-bar tap. Pre-expands the Verlauf disclosure
        /// (so the history is one tap closer) but does NOT auto-scroll the page;
        /// the screen still opens at the top. Only `.history` (genuine reminder /
        /// URL deep links) scrolls down to the Verlauf anchor.
        case compliance
    }

    let id: String
    let focus: Focus

    public init(id: String, focus: Focus = .overview) {
        self.id = id
        self.focus = focus
    }
}

struct PersonalRecordRoute: Hashable {
    let id: String
}

/// #42 (v1.27.6) — typed `morePath` payload for the mental-health check-in
/// surface (`MentalWellbeingScreen`). Pushed by
/// ``AppRouter/requestMentalWellbeingCheckIn()`` when a screening reminder
/// (`PHQ9_SCORE` / `GAD7_SCORE` / `WHO5_SCORE`) is actioned, so a derived
/// screening score routes to the self-check instead of a numeric capture form.
/// Resolved by a sibling `.navigationDestination(for:)` in `MoreScreen` (the
/// same mechanism as `PersonalRecordRoute` / `SettingsRoute`). Carries no
/// payload — the screen opens at its instrument chooser.
struct MentalWellbeingRoute: Hashable {}

/// **Parity 1.10 — typed `morePath` payload for the per-kind values table
/// (`MeasurementListScreen`).**
///
/// The screen already existed and was reachable by hand (Mehr → Messwerte →
/// row), but only ever as an inline `NavigationLink` destination — there was no
/// route the router could push. That is why
/// ``AppRouter/selectInsightsMetric(_:)`` had nowhere to go when a `MetricKind`
/// carried no Insights slug, and simply logged instead. Resolved by a sibling
/// `.navigationDestination(for:)` in `MoreScreen`.
struct MeasurementListRoute: Hashable {
    let kind: MetricKind
}
