import Foundation
@testable import HealthLog
import Testing

/// v0.12 W0 — navigation-graph deep-link wiring. Each test asserts that a
/// `DeepLinkRoute` applied to `AppRouter` lands the operator on the right tab +
/// pushes (or selects) the right surface, rather than dead-ending at a tab root
/// or teleporting to Dashboard.
///
/// `AppRouter` is `@MainActor @Observable`; the suite is `@MainActor` so it can
/// read the path/selection state directly. We assert on the OBSERVABLE shape of
/// the router (tab, per-tab `NavigationPath.count`, the parked Insights slug +
/// counter) — the typed `NavigationPath` payloads aren't introspectable, so
/// `count == 1` is the proxy for "a detail route was pushed onto this stack".
@MainActor
@Suite("AppRouter navigation graph (W0)")
struct AppRouterNavigationTests {
    private func url(_ string: String) throws -> URL {
        try #require(URL(string: string), "Test-Fixture URL ungültig: \(string)")
    }

    /// W0-1 — `MedicationDetailRoute` is pushed onto the (now-bound) `medsPath`.
    @Test("medication route → Meds tab + one pushed detail")
    func medicationRoutepushesDetail() {
        let router = AppRouter()
        router.apply(.medication(id: "med_abc"), isAuthenticated: true)
        #expect(router.selectedTab == .meds)
        #expect(router.medsPath.count == 1)
    }

    /// W0-1 — `…/history` deep link pushes a detail route with `.history` focus
    /// (the focus rides inside the `MedicationDetailRoute` payload; the stack
    /// still shows exactly one pushed entry).
    @Test("medicationHistory route → Meds tab + one pushed detail")
    func medicationHistoryRoutePushesDetail() {
        let router = AppRouter()
        router.apply(.medicationHistory(id: "med_abc"), isAuthenticated: true)
        #expect(router.selectedTab == .meds)
        #expect(router.medsPath.count == 1)
    }

    /// W0-fix (review M1) — the `.history` focus actually survives the route
    /// mapping. NavigationPath payloads aren't introspectable, so we assert the
    /// pure mapping the router uses: a regression dropping `.history` (e.g. back
    /// to the default `.overview`) fails HERE, closing the W0-2 ship-gate's
    /// previously-untested headline behaviour ("reminder lands on the history").
    @Test("medicationHistory maps to a detail route carrying .history focus")
    func medicationHistoryCarriesHistoryFocus() {
        #expect(AppRouter.medicationDetailRoute(for: .medicationHistory(id: "med_abc"))?.focus == .history)
        // The plain medication route must NOT carry .history (else every reminder
        // would force-scroll to Verlauf).
        #expect(AppRouter.medicationDetailRoute(for: .medication(id: "med_abc"))?.focus != .history)
        #expect(AppRouter.medicationDetailRoute(for: .dashboard) == nil)
    }

    /// v0153 M1 — the `.compliance` focus is an IN-APP card-tap affordance
    /// (`onComplianceTap` → opens at the top, pre-expanded Verlauf, NO scroll),
    /// never a router deep-link. A genuine reminder/URL deep link must keep
    /// `.history` (which DOES scroll) and must never resolve to `.compliance`,
    /// so the card-tap's no-scroll behaviour can't leak onto notification taps.
    @Test("router deep-links never carry .compliance focus (M1 — card-tap only)")
    func deepLinksNeverCarryComplianceFocus() {
        #expect(AppRouter.medicationDetailRoute(for: .medicationHistory(id: "med_abc"))?.focus != .compliance)
        #expect(AppRouter.medicationDetailRoute(for: .medication(id: "med_abc"))?.focus != .compliance)
    }

    /// W0-fix (review H1) — the parked Insights slug is ONE-SHOT. After the
    /// container consumes a deep-linked metric once, a bare re-consume (no new
    /// deep link — e.g. a tab switch / scenePhase re-appear) returns `.none`, so
    /// the pager is NOT re-snapped back to the stale metric. This is the exact
    /// "tap a chart → wrong page seconds later" regression class.
    @Test("consumePendingInsightsMetric is one-shot per request bump")
    func insightsMetricConsumeIsOneShot() {
        let router = AppRouter()
        router.apply(.insights(metric: "blood-pressure"), isAuthenticated: true)
        // First consume yields a fresh request (outer .some) carrying the slug…
        let first = router.consumePendingInsightsMetric()
        #expect(first != nil) // outer .some — a fresh request to apply
        #expect(first == .some("blood-pressure")) // inner slug
        // …a second consume with NO new bump yields nothing (no stale re-snap).
        #expect(router.consumePendingInsightsMetric() == nil) // outer .none
        // A fresh deep link bumps again → consumable once more.
        router.apply(.insights(metric: "pulse"), isAuthenticated: true)
        let second = router.consumePendingInsightsMetric()
        #expect(second == .some("pulse"))
        #expect(router.consumePendingInsightsMetric() == nil)
    }

    /// W0-1/W0-3 — `.insights(metric:)` is routed through the container
    /// selection signal, NOT a `NavigationPath` push. The slug is parked + the
    /// counter bumped; `insightsPath` stays empty (the ghost `InsightsDetailRoute`
    /// is gone).
    @Test("insights(metric:) → Insights tab + parked slug, no path push")
    func insightsMetricParksSlug() {
        let router = AppRouter()
        router.apply(.insights(metric: "blood-pressure"), isAuthenticated: true)
        #expect(router.selectedTab == .insights)
        #expect(router.insightsPath.isEmpty)
        #expect(router.pendingInsightsMetricSlug == "blood-pressure")
        #expect(router.insightsMetricRequestCount == 1)
    }

    /// W0-3 — bare `.insights(metric: nil)` selects Insights + parks `nil`
    /// (Übersicht) and bumps the counter so the container resolves to overview.
    @Test("insights(metric: nil) → Insights tab + nil slug, counter bumped")
    func insightsBareSelectsOverview() {
        let router = AppRouter()
        router.apply(.insights(metric: nil), isAuthenticated: true)
        #expect(router.selectedTab == .insights)
        #expect(router.pendingInsightsMetricSlug == nil)
        #expect(router.insightsMetricRequestCount == 1)
    }

    /// v0.13.1 IC — the Dashboard tile-tap nav-unification entry point. A tap
    /// drives `selectInsightsMetric(_:)`, which resolves the kind to its slug
    /// and routes through the SAME `.insights(metric:)` path — landing the
    /// operator in the Insights tab on that metric's page (not a duplicate
    /// detail pushed onto the Home stack).
    @Test("selectInsightsMetric(kind) → Insights tab + parked slug for that kind")
    func selectInsightsMetricLandsInTab() {
        let router = AppRouter()
        router.selectInsightsMetric(.bloodPressure)
        #expect(router.selectedTab == .insights)
        #expect(router.insightsPath.isEmpty)
        #expect(router.pendingInsightsMetricSlug == "blood-pressure")
        #expect(router.insightsMetricRequestCount == 1)
    }

    /// IC — cardio-fitness was the one-line slug gap: `.vo2Max` had a descriptor
    /// + Dashboard tile but no Insights slug, so it never produced a pill. The
    /// reverse helper now resolves it, so a VO₂-max tile tap lands correctly.
    @Test("selectInsightsMetric(.vo2Max) resolves the cardio-fitness slug")
    func selectInsightsMetricResolvesVo2Max() {
        let router = AppRouter()
        router.selectInsightsMetric(.vo2Max)
        #expect(router.selectedTab == .insights)
        #expect(router.pendingInsightsMetricSlug == "cardio-fitness")
    }

    /// v0.14.1 §6 — the wellness-score detail sheet's contributor deep-nav.
    /// Tapping a contributor (e.g. Ruhepuls) previously pushed a BARE
    /// `InsightsMetricScreen` onto the Insights screen's local stack — a
    /// dead-end with no tab strip, no swipe, no back. It now routes through the
    /// SAME `selectInsightsMetric(_:)` deep link a Dashboard tile uses, so the
    /// contributor lands on the NAVIGABLE paged `InsightsContainerScreen` page
    /// (sticky strip + swipe + back). Asserts the router parks the resting-HR
    /// slug + bumps the counter the container consumes onto its pager selection.
    @Test("wellness-sheet contributor (resting HR) → navigable Insights metric page")
    func wellnessContributorDeepNavLandsNavigable() {
        let router = AppRouter()
        // Simulate the contributor row's tap → onSelectMetric closure.
        router.selectInsightsMetric(.restingHeartRate)
        #expect(router.selectedTab == .insights)
        #expect(router.insightsPath.isEmpty) // no bare push onto a local stack
        #expect(router.pendingInsightsMetricSlug == "resting-pulse")
        #expect(router.insightsMetricRequestCount == 1)
        // The container consumes the fresh request exactly once → pager selects
        // the metric page (navigable: strip + swipe + back).
        #expect(router.consumePendingInsightsMetric() == .some("resting-pulse"))
    }

    /// v0.14.3 F3 — the Stimmung (mood) contributor in the wellness-score detail
    /// sheet is NOT a chartable `MetricKind`; it routes through the special-page
    /// seam `selectInsightsSpecial(.mood)`, which parks the mood layout slug so
    /// `InsightsContainerScreen` resolves it onto its pager via
    /// `InsightsSpecialPage.page(forSlug:)` (navigable strip + swipe + back, no
    /// dead-end). Asserts the slug parks + the container consumes it once.
    @Test("wellness-sheet mood contributor → navigable Mood special Insights page")
    func wellnessMoodContributorDeepNavLandsNavigable() {
        let router = AppRouter()
        // Simulate the mood contributor row's tap → onSelectMood closure.
        router.selectInsightsSpecial(.mood)
        #expect(router.selectedTab == .insights)
        #expect(router.insightsPath.isEmpty) // no bare push onto a local stack
        #expect(router.pendingInsightsMetricSlug == "mood")
        #expect(router.insightsMetricRequestCount == 1)
        // The parked mood slug resolves to the Mood special page.
        #expect(router.consumePendingInsightsMetric() == .some("mood"))
        #expect(InsightsSpecialPage.page(forSlug: "mood") == .mood)
    }

    /// W0-1 — `PersonalRecordRoute` is pushed onto the More stack.
    @Test("personalRecord route → More tab + one pushed entry")
    func personalRecordRoutePushes() {
        let router = AppRouter()
        router.apply(.personalRecord(id: "pr_abc"), isAuthenticated: true)
        #expect(router.selectedTab == .more)
        #expect(router.morePath.count == 1)
    }

    /// W0-1 — `.settingsNotifications` pushes Settings THEN Notifications onto
    /// the More stack (back stack: Mehr → Settings → Notifications).
    @Test("settingsNotifications route → More tab + two pushed entries")
    func settingsNotificationsRoutePushesTwo() {
        let router = AppRouter()
        router.apply(.settingsNotifications, isAuthenticated: true)
        #expect(router.selectedTab == .more)
        #expect(router.morePath.count == 2)
    }

    /// W0-2 (ship gate) — a med-reminder body-tap synthesises
    /// `healthlog://medications/<id>`. Parsing + applying it must land on the
    /// Meds tab with the dose detail pushed — not the list root.
    @Test("med-reminder URL → Meds tab + pushed dose detail (ship gate)")
    func medReminderURLPushesDetail() throws {
        let route = try #require(DeepLinkRoute(url: url("healthlog://medications/med_xyz")))
        #expect(route == .medication(id: "med_xyz"))
        let router = AppRouter()
        router.apply(route, isAuthenticated: true)
        #expect(router.selectedTab == .meds)
        #expect(router.medsPath.count == 1)
    }

    /// W0-2 — the no-id fallback `healthlog://medications` now parses to
    /// `.medications` (Meds list root), NOT `.unknown` → Dashboard. Applying it
    /// selects the Meds tab with an empty stack.
    @Test("no-id med fallback → Meds tab root, NOT Dashboard")
    func noIdFallbackSelectsMedsRoot() throws {
        let route = try #require(DeepLinkRoute(url: url("healthlog://medications")))
        #expect(route == .medications)
        let router = AppRouter()
        // Pre-seed a different tab so we can prove the route moves to Meds.
        router.selectedTab = .home
        router.apply(route, isAuthenticated: true)
        #expect(router.selectedTab == .meds)
        #expect(router.medsPath.isEmpty)
    }

    /// W0-2 regression — an unknown route still falls back to Dashboard, so the
    /// new `.medications` root case didn't widen the fallback surface.
    @Test("unknown route still falls back to Dashboard")
    func unknownStillFallsToDashboard() throws {
        let route = try #require(DeepLinkRoute(url: url("healthlog://this-does-not-exist")))
        let router = AppRouter()
        router.selectedTab = .meds
        router.apply(route, isAuthenticated: true)
        #expect(router.selectedTab == .home)
    }

    /// Cold-start-from-tap: applying a route while unauthenticated parks it in
    /// `pendingRoute`; consuming it after auth resolves to the detail push.
    @Test("unauthenticated medication route parks, then resolves on consume")
    func pendingRouteResolvesAfterAuth() {
        let router = AppRouter()
        router.apply(.medication(id: "med_abc"), isAuthenticated: false)
        #expect(router.medsPath.isEmpty)
        router.consumePendingRoute()
        #expect(router.selectedTab == .meds)
        #expect(router.medsPath.count == 1)
    }

    // MARK: - b182 W-B182-INVITE (GH #16)

    private static let inviteToken = "hlv_" + String(repeating: "a", count: 64)

    /// `.invite` is AUTH-AGNOSTIC: it parks `pendingInviteToken` regardless of
    /// auth phase (unlike `pendingRoute`, which only fires post-auth). The invite
    /// must surface BEFORE auth in onboarding registration.
    @Test("invite route parks token regardless of auth phase (unauthenticated)")
    func inviteParksTokenWhenUnauthenticated() {
        let router = AppRouter()
        router.apply(.invite(token: Self.inviteToken), isAuthenticated: false)
        #expect(router.pendingInviteToken == Self.inviteToken)
        // It must NOT also go through the normal post-auth pendingRoute path.
        #expect(router.pendingRoute == nil)
    }

    /// W-INVITE-DEEPLINK (#16) — an already-signed-in user tapping an invite link
    /// does NOT park the token (an invite creates a NEW account; it can't be
    /// applied to the current session). Instead the router bumps a non-destructive
    /// notice counter the shell surfaces, and leaves the current tab untouched (no
    /// scary re-register teleport). NO sensitive token is held in this case.
    @Test("invite route while authenticated → notice bumped, token NOT parked, no nav teleport")
    func inviteWhileAuthenticatedSurfacesNotice() {
        let router = AppRouter()
        router.selectedTab = .meds
        #expect(router.inviteWhileSignedInNoticeCount == 0)
        router.apply(.invite(token: Self.inviteToken), isAuthenticated: true)
        // Token must NOT be parked on a signed-in session.
        #expect(router.pendingInviteToken == nil)
        // The non-destructive notice fired.
        #expect(router.inviteWhileSignedInNoticeCount == 1)
        // Current tab untouched — no re-register teleport.
        #expect(router.selectedTab == .meds)
        // It must NOT go through the normal post-auth pendingRoute path either.
        #expect(router.pendingRoute == nil)
    }

    /// Back-to-back invite taps while signed in re-bump the notice counter so the
    /// shell re-presents even before it has processed the previous edge.
    @Test("invite while authenticated bumps the notice counter each tap")
    func inviteWhileAuthenticatedReBumpsNotice() {
        let router = AppRouter()
        router.apply(.invite(token: Self.inviteToken), isAuthenticated: true)
        router.apply(.invite(token: Self.inviteToken), isAuthenticated: true)
        #expect(router.inviteWhileSignedInNoticeCount == 2)
        #expect(router.pendingInviteToken == nil)
    }

    /// `consumePendingInviteToken()` is one-shot — clears on read so a re-appear
    /// (scenePhase / tab churn) doesn't re-trigger the invite flow.
    @Test("consumePendingInviteToken is one-shot")
    func consumeInviteTokenIsOneShot() {
        let router = AppRouter()
        router.apply(.invite(token: Self.inviteToken), isAuthenticated: false)
        #expect(router.consumePendingInviteToken() == Self.inviteToken)
        // Second consume yields nil (cleared).
        #expect(router.consumePendingInviteToken() == nil)
        #expect(router.pendingInviteToken == nil)
    }

    /// The 403-invite error classifier (`HLError.isInvalidInviteError`) used by
    /// `RegistrationSheet` to map the server's "Invalid or expired invite" /
    /// "Registration is disabled" 403 to the localized inline message.
    @Test("invalid-invite error classifier matches a 403, not other statuses")
    func invalidInviteErrorClassifier() {
        #expect(HLError.server(status: 403, code: nil, message: "Invalid or expired invite").isInvalidInviteError)
        #expect(!HLError.server(status: 409, code: nil, message: "taken").isInvalidInviteError)
        #expect(!HLError.unauthorized.isInvalidInviteError)
        let none: HLError? = nil
        #expect(none?.isInvalidInviteError != true)
    }

    // MARK: - Parity 1.10 — dead-tap safety net

    /// A `MetricKind` with no Insights slug used to make `selectInsightsMetric`
    /// log a line and return. Four such kinds ship a dashboard tile today, so
    /// the tile looked tappable and did nothing at all — the operator cannot
    /// distinguish that from a frozen app, and the only evidence was in a log.
    ///
    /// The kind is found rather than hardcoded: a later build wires the four
    /// missing slugs, and this test should keep guarding the CLASS of bug for
    /// whatever kind is next added without one, not fail because a specific kind
    /// got fixed.
    @Test("A kind with no Insights slug falls back to the values table, not a no-op")
    func slugLessKindFallsBackToMeasurementList() throws {
        // b241 Fix 1 — `.mood` is slug-less too but now routes to its dedicated
        // Mood Insights special page (not the values table), so it must be
        // excluded from the "slug-less ⇒ values table" guard below.
        let slugLess = try #require(
            MetricKind.allCases.first { InsightsTabSlug.slug(forKind: $0) == nil && $0 != .mood },
            "No slug-less MetricKind left — retire this test or pick a different guard."
        )
        let router = AppRouter()
        router.selectInsightsMetric(slugLess)

        #expect(router.selectedTab == .more)
        #expect(router.morePath.count == 1)
        // It must NOT have gone down the Insights path with a nil slug, which
        // would land the operator on the overview — a different wrong answer.
        #expect(router.pendingInsightsMetricSlug == nil)
        #expect(router.insightsMetricRequestCount == 0)
    }

    /// The fallback must not fire for kinds that DO resolve — the happy path
    /// still goes to Insights.
    @Test("A kind with a slug is unaffected by the fallback")
    func sluggedKindStillRoutesToInsights() {
        let router = AppRouter()
        router.selectInsightsMetric(.weight)
        #expect(router.selectedTab == .insights)
        #expect(router.morePath.isEmpty)
        #expect(router.pendingInsightsMetricSlug != nil)
    }

    @Test("showMeasurementList lands on the Mehr stack")
    func showMeasurementListPushesOntoMorePath() {
        let router = AppRouter()
        router.showMeasurementList(.weight)
        #expect(router.selectedTab == .more)
        #expect(router.morePath.count == 1)
    }

    // MARK: - b241 Fix 1 — mood tile tap routes to mood history, not measurements

    /// b241 Fix 1 — a mood Dashboard tile tap drives `selectInsightsMetric(.mood)`.
    /// Mood is a `MoodEntry` served only by `/api/mood-entries` (`MoodStore`),
    /// never a `Measurement`, so the previous slug-less fallback landed on
    /// `MeasurementListScreen(kind: .mood)` — a `/api/measurements` query that is
    /// ALWAYS empty ("Noch keine Messungen") even with 483 mood rows. The tap now
    /// routes to the dedicated Mood Insights special page (`InsightsMoodPage`,
    /// which reads `MoodStore.entries`) instead: Insights tab, mood slug parked,
    /// and CRUCIALLY it must NOT push a `MeasurementListRoute(kind: .mood)` onto
    /// the Mehr stack.
    @Test("mood tile tap → navigable Mood special Insights page, NOT the measurement list")
    func moodTileTapRoutesToMoodHistory() {
        let router = AppRouter()
        router.selectInsightsMetric(.mood)
        #expect(router.selectedTab == .insights)
        // It must NOT land on the (always-empty) measurements values table.
        #expect(router.selectedTab != .more)
        #expect(router.morePath.isEmpty)
        // The parked slug resolves to the Mood special page (reads MoodStore).
        #expect(router.pendingInsightsMetricSlug == "mood")
        #expect(router.insightsMetricRequestCount == 1)
        #expect(router.consumePendingInsightsMetric() == .some("mood"))
        #expect(InsightsSpecialPage.page(forSlug: "mood") == .mood)
    }
}
