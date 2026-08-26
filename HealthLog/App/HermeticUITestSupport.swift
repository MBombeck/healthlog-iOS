#if DEBUG
    import Foundation

    /// **W-HERMETIC-E2E (v0152).** Debug-only UI-test infrastructure that boots
    /// the app into a deterministic, network-free authenticated state.
    ///
    /// The seven `HealthLogUITests` walkthrough classes used to authenticate
    /// against the LIVE `demo.healthlog.dev` backend via the onboarding wizard —
    /// fragile (server flakiness, locale-renamed CTAs, "Welcome CTA missing",
    /// onboarding gate) and impossible in CI / offline. The `-uitest-hermetic`
    /// launch argument replaces that entire path:
    ///
    /// 1. ``HermeticURLProtocol`` is registered + injected into the API session
    ///    so EVERY HTTP request to the seeded host resolves from bundled JSON
    ///    fixtures with NO network.
    /// 2. The keychain is seeded with a fake auth token + `userID` + the seeded
    ///    server URL so `AuthStore.bootstrap()` resolves straight to
    ///    `.authenticated` (skipping onboarding entirely).
    /// 3. The disclaimer + biometric gates are pre-acked.
    ///
    /// The whole file is wrapped in `#if DEBUG`, so NONE of it links into a
    /// Release build — verified by the `release-build-has-no-hermetic-symbols`
    /// check in the report. The seam reuses the existing UI-test bootstrap
    /// (`applyUITestEnvironmentOverrides`) rather than inventing a parallel one.
    enum HermeticUITestSupport {
        static let launchArgument = "-uitest-hermetic"

        /// **H3 auth-journey (audit-v0162).** Boots UNAUTHENTICATED onto the
        /// onboarding auth step with the SAME fixture-backed backend as the
        /// authenticated hermetic boot, so a UITest can drive the *real* login
        /// form — password → shell, and the second-factor `MfaChallengeSheet` —
        /// with zero network. Unlike `-uitest-hermetic` it seeds NO auth token,
        /// so `AuthStore.bootstrap()` resolves to `.unauthenticated` →
        /// `OnboardingFlow` (which, in DEBUG under this flag, opens straight on
        /// its `.auth` step — see `OnboardingFlow.initialStep`). The login / MFA
        /// responses the fixtures serve are steered by the companion args
        /// `-uitest-mfa-challenge`, `-uitest-mfa-verify-wrong`, and
        /// `-uitest-mfa-verify-dead` (see `HermeticFixtures`).
        static let authJourneyArgument = "-uitest-auth-journey"

        /// **Phase 08 Wave 0.** The one typed scenario vocabulary the Phase-8 UI
        /// REDs steer their fixtures with. Passed as `-uitest-phase8 <rawValue>`
        /// and read here, before ``AppContainer`` composes anything, so the
        /// scenario can only ever change what the *fixtures* answer — there is
        /// no release-path conditional anywhere in this vocabulary and the whole
        /// file is `#if DEBUG`.
        ///
        /// Each case is owned by exactly one test, so a scenario can never drift
        /// into meaning two things at once.
        enum Phase8Scenario: String, CaseIterable, Sendable {
            /// The authenticated shell on the default fixtures — the release
            /// surfaces (medication, About, support, logout, audit).
            case releaseSurface
            /// A document list whose newest filter answers slowly, so a stale
            /// result has a window in which it can still be on screen.
            case documentsDelayedFilter
            /// A bulk action the server half-refuses.
            case documentsPartialBulk
            /// Every `/api/documents/inbound*` route answers `403
            /// module.disabled` while the module gate still reads enabled.
            case documentsModuleDisabled
            /// An unauthenticated boot whose `/api/auth/me` says the tour is
            /// already complete — the returning user who should not be re-asked.
            case returningLoginCompleted
            /// **08-08.** The same boot for an account whose setup is genuinely
            /// outstanding: `/api/auth/me` answers `onboardingTourCompleted:
            /// false`, so the optional tail is reached truthfully rather than by
            /// the flow ignoring the answer. Every case that asserts *about* the
            /// permission / profile / progress steps needs this one; before
            /// Wave 1 they could reach the tail under any scenario, because the
            /// route never consulted anything.
            case returningLoginIncomplete
            /// The optional profile step, with its write refused server-side.
            /// Its `/api/auth/me` also says the tour is outstanding — the step it
            /// exercises lives inside the setup tail.
            case onboardingProfileFailure
            /// **08-11.** The authenticated shell with four renderable wellness
            /// scores on the derived batch route, so the Insights score grid has
            /// something to lay out. Without it `/api/insights/*` answers `{}`,
            /// the block self-suppresses, and an accessibility-size layout case
            /// would assert about an empty screen — the shape of hermetic
            /// fixture 08-10 found guarding a route the app never calls.
            case insightsAccessibility
        }

        static let phase8Argument = "-uitest-phase8"

        /// **13-04 — the web-handoff outcome, without a browser.**
        ///
        /// `ASWebAuthenticationSession` presents a system sheet out of process.
        /// A UI test cannot drive it, and a test that tried would be measuring
        /// Safari. So the *outcome* is the seam: this argument installs a stub
        /// authenticator (`AppContainer`, DEBUG only) that returns the named
        /// terminal outcome without ever opening a sheet, which is exactly the
        /// boundary `AuthStore` already treats as its input.
        ///
        /// The REAL browser leg against a REAL server is not simulated here and
        /// is not claimed to be: it is `P13-AUTH-01` in the device-UAT ledger,
        /// and it stays pending on hardware.
        enum WebLoginOutcome: String, CaseIterable, Sendable {
            /// The session handed back the address it died on rather than the
            /// app's callback — the shape healthlog-iOS#96 produces.
            case deadEnd = "dead-end"
            /// The session could not start or ended with no callback at all.
            case failed
            /// The user dismissed the sheet.
            case cancelled
        }

        static let webLoginOutcomeArgument = "-uitest-weblogin-outcome"

        /// **13-04 — this run is about the web-handoff leg.**
        ///
        /// Scoped deliberately rather than made the fixture default. The
        /// availability gate is honest now (13-02): on a self-hosted instance
        /// whose login route answers, the browser CTA takes the primary slot
        /// and the password form starts closed behind the fallback link. That
        /// is #65's shipped design and it is correct — and it means a fixture
        /// server that suddenly serves `/api/version` and the login route
        /// changes what EVERY auth-journey test sees. `AuthJourneyUITest` is
        /// about the native password/MFA route and its world must stay the
        /// world it has always had: a server that does not serve the
        /// web-handoff contract, where the password form is the primary door.
        ///
        /// So the two routes are served only when this argument is present,
        /// and only `WebLoginJourneyUITest` passes it.
        static let webLoginRoutesArgument = "-uitest-weblogin"

        /// Whether the fixture backend should answer the web-handoff
        /// availability probe affirmatively.
        static var servesWebLoginRoutes: Bool {
            ProcessInfo.processInfo.arguments.contains(webLoginRoutesArgument)
        }

        /// The stubbed web-handoff outcome, or `nil` outside such a test.
        static var webLoginOutcome: WebLoginOutcome? {
            let arguments = ProcessInfo.processInfo.arguments
            guard let index = arguments.firstIndex(of: webLoginOutcomeArgument),
                  arguments.index(after: index) < arguments.endIndex else { return nil }
            return WebLoginOutcome(rawValue: arguments[arguments.index(after: index)])
        }

        /// The address the stub hands back for ``WebLoginOutcome/deadEnd`` —
        /// the operator's instance's own answer, verbatim from the measurement
        /// in healthlog-iOS#96.
        static let deadEndCallbackURL = "https://0.0.0.0:3000/auth/login?flow=native"

        /// The active Phase-8 scenario, or `nil` outside a Phase-8 UI test.
        static var phase8Scenario: Phase8Scenario? {
            let arguments = ProcessInfo.processInfo.arguments
            guard let index = arguments.firstIndex(of: phase8Argument),
                  arguments.index(after: index) < arguments.endIndex else { return nil }
            return Phase8Scenario(rawValue: arguments[arguments.index(after: index)])
        }

        /// Stable seed values — the fixtures reference the same `userID`.
        static let seededHost = "uitest.hermetic.local"
        static let seededBaseURL = "https://uitest.hermetic.local"
        static let seededUserID = "hermetic-user"
        static let seededDisplayName = "Hermetic Tester"

        /// The authenticated hermetic boot (`-uitest-hermetic`) — straight to the
        /// dashboard with a seeded token.
        static var isAuthenticatedBoot: Bool {
            ProcessInfo.processInfo.arguments.contains(launchArgument)
        }

        /// The unauthenticated auth-journey boot (`-uitest-auth-journey`) — the
        /// login form with a stubbed backend, no token.
        static var isAuthJourneyBoot: Bool {
            ProcessInfo.processInfo.arguments.contains(authJourneyArgument)
        }

        /// `true` for EITHER hermetic mode — the flag that stubs the backend
        /// (`HermeticURLProtocol` interception + `AppContainer` session injection).
        /// Both boots resolve every request against the same seeded host so the
        /// interception scope is identical.
        static var isActive: Bool {
            isAuthenticatedBoot || isAuthJourneyBoot
        }

        /// Seed the keychain + UserDefaults so `AuthStore.bootstrap()` lands on
        /// `.authenticated` and the onboarding/disclaimer/biometric gates are
        /// satisfied. Runs from `applyUITestEnvironmentOverrides` BEFORE
        /// `AppEnvironment.resolve`, so the seeded base URL wins. `@MainActor`
        /// because the seeded keys (`SyncModeStore`, `FirstLoginSyncBanner`) are
        /// MainActor-isolated; the caller (`HealthLogApp.init`) is on MainActor.
        @MainActor
        static func seedAuthenticatedSession(keychain: KeychainStoring) {
            guard isAuthenticatedBoot else { return }
            // Purge any residue from a previous run on a reused simulator first.
            try? keychain.removeAll()
            try? keychain.setString(seededBaseURL, forKey: KeychainKey.serverURL)
            try? keychain.setString("hermetic-bearer-token", forKey: KeychainKey.authToken)
            try? keychain.setString(seededUserID, forKey: KeychainKey.userID)
            try? keychain.setString(seededDisplayName, forKey: KeychainKey.userDisplayName)
            // `.paired` sync + onboarding mode so SyncModeStore resolves a
            // non-nil paired mode and never drops into the standalone /
            // re-onboard branch.
            UserDefaults.standard.set("paired", forKey: SyncModeStore.storageKey)
            UserDefaults.standard.set("paired", forKey: SyncModeStore.onboardingModeKey)
            // Disable the biometric-lock gate (no enrolled biometric on CI sims).
            UserDefaults.standard.set(false, forKey: "hl.settings.biometricLock")
            // Mark the first-login banner consumed so the walkthrough lands on a
            // clean dashboard.
            UserDefaults.standard.set(true, forKey: FirstLoginSyncBanner.completedDefaultsKey)
            purgePermissionPromptingResidue()
            HermeticURLProtocol.activate()
        }

        /// **CU-05.** Device-local UI-pref residue that makes a hermetic boot ask
        /// iOS for a *system permission sheet* — the one class of leftover that
        /// survives a keychain purge and then hijacks the NEXT test.
        ///
        /// Concretely: `CycleToggleFlipUITest` drives the real opt-in path, so it
        /// leaves `hl.settings.cycleTracking.optIn == true` in `UserDefaults` on the
        /// shared simulator. Every later launch re-opens `CycleGate`, and the
        /// foreground pass (`RootView.handle(scenePhase:)` →
        /// `CycleStore.refreshGateLifecycle` → `requestCycleAuthorizationIfNeeded`)
        /// then raises the reproductive-category HealthKit authorization sheet.
        /// That sheet is presented OUT OF PROCESS on top of the app, so it swallows
        /// taps and drops the app's own subtree out of the accessibility snapshot —
        /// the following test sees a Dashboard that will not switch tabs and an
        /// Insights surface that "never renders" (`InsightsPagerOrderUITest` /
        /// `InsightsW5aWalkthroughTest`). Nobody ever answers it, so the types stay
        /// undetermined and it comes back on every launch; whether it wins the race
        /// against the test's first tap is what made the failure intermittent.
        ///
        /// A hermetic boot is supposed to be as deterministic about the DEVICE as
        /// `HermeticURLProtocol` is about the network — so the seed purges the flag
        /// exactly like it purges the keychain. A test that WANTS the opt-in on
        /// passes it via `-hl.settings.cycleTracking.optIn` (the argument domain
        /// wins over the persistent one), so this cannot disarm such a test.
        ///
        /// **09-16 — a second residue of the same shape, and an honest limit on
        /// what removing it buys.** `MarketingScreenshotsTest` taps
        /// `healthkitConnectBanner.dismissButton` for a calmer hero shot;
        /// `HKReadinessStore.dismissBanner()` persists
        /// `hl.healthkit.bannerDismissedAt.<token>` with a **24-hour** cooldown, and
        /// that class sorts before `Phase8AccessibilityUITests`. 08-23 measured the
        /// consequence by deleting exactly that key between two otherwise identical
        /// gates: `testFocusedAccessibilityAudit` went from auditing the
        /// medication-adherence card back to auditing the HealthKit banner. A key a
        /// sibling test writes has no business deciding which screen an
        /// accessibility audit reports on, so the seed removes it.
        ///
        /// **09-16's honest limit, and what 12-12 measured it to be.** 09-16 read the
        /// banner Dashboard once in ten and could not say why, so it warned that
        /// removing the dismissal key was correct and insufficient. It was: the
        /// dismissal key is one of **three** `hl.healthkit.*` keys that decide this
        /// screen, and the other two were left in place.
        ///
        /// `hl.healthkit.requestedAt.<token>` is the sticky one.
        /// `HKReadinessStore.isConnected` returns `true` for any post-sheet state
        /// that is not `.denied`, and `shouldShowDashboardBanner` refuses on
        /// `isConnected` **before** it ever looks at the dismissal cooldown — so one
        /// run that reached the HealthKit permission path (`HealthKitPermissionStep`
        /// on the onboarding walk, `requestAuthorization()` from a stray tap on the
        /// banner's own Connect CTA, or `refresh()`'s migration self-heal on a
        /// simulator whose HealthKit database already holds a granted write type)
        /// hides the banner on **every later run on that device**, one-way, until
        /// somebody removes the key by hand. `hl.healthkit.lastSyncedAt.<token>` is
        /// the same arithmetic one clause earlier.
        ///
        /// 12-12 measured all three legs: 12 of 12 runs audited the banner Dashboard
        /// with the keys absent; planting `requestedAt` alone moved the audit to the
        /// other Dashboard and its disjoint finding set; and the key then survived a
        /// full launch untouched, so the next run reported the wrong screen too. The
        /// seed therefore clears the readiness partition outright, through
        /// `clearPersisted` — the store's own enumeration of its keys, so this list
        /// cannot drift away from the list that matters.
        ///
        /// This is still not a determinism *guarantee*, and the remaining gap is
        /// named rather than papered over: the simulator's HealthKit authorization
        /// database lives outside the app container, survives `simctl uninstall`, and
        /// no seed can reach it — a granted write type there re-marks `requestedAt`
        /// through `refresh()`'s migration. That case is now a **named failure**
        /// instead of a silent substitution, because `testFocusedAccessibilityAudit`
        /// asserts the Dashboard it audits.
        ///
        /// A test that WANTS the banner gone still dismisses it inside its own run,
        /// exactly as `MarketingScreenshotsTest` does — so this cannot disarm one
        /// either.
        @MainActor
        private static func purgePermissionPromptingResidue() {
            UserDefaults.standard.removeObject(forKey: "hl.settings.cycleTracking.optIn")
            HKReadinessStore.clearPersisted(for: seededUserID)
        }

        /// **H3 auth-journey (audit-v0162).** Seed the UNAUTHENTICATED auth-journey
        /// boot: the seeded server URL so the login `POST` resolves against the
        /// fixture host, but NO auth token — the app stays on the onboarding auth
        /// step (`AuthStore.bootstrap()` → `.unauthenticated`). Activates the
        /// fixture protocol so the login / MFA-verify endpoints answer from
        /// `HermeticFixtures`. Purges residual mode keys so a reused simulator
        /// can't bootstrap into a shell. `@MainActor` for parity with
        /// `seedAuthenticatedSession` (SyncModeStore keys are MainActor-adjacent).
        @MainActor
        static func seedAuthJourney(keychain: KeychainStoring) {
            guard isAuthJourneyBoot else { return }
            try? keychain.removeAll()
            try? keychain.setString(seededBaseURL, forKey: KeychainKey.serverURL)
            // No token AND no paired/standalone mode → bootstrap resolves cleanly
            // to `.unauthenticated`, mounting `OnboardingFlow` (opened on `.auth`).
            UserDefaults.standard.removeObject(forKey: SyncModeStore.storageKey)
            UserDefaults.standard.removeObject(forKey: SyncModeStore.onboardingModeKey)
            UserDefaults.standard.set(false, forKey: "hl.settings.biometricLock")
            // Same residue purge as the authenticated boot — the auth-journey run
            // ends up in the very same shell once the login lands.
            purgePermissionPromptingResidue()
            HermeticURLProtocol.activate()
        }
    }

    /// A `URLProtocol` that intercepts every request in `-uitest-hermetic` runs
    /// and answers from in-memory fixtures — zero network. Registered globally
    /// (`URLProtocol.registerClass`) AND injected into the API session's
    /// `protocolClasses` (see `AppContainer`) so both the shared session and the
    /// app's custom pinned sessions are covered.
    final class HermeticURLProtocol: URLProtocol, @unchecked Sendable {
        static func activate() {
            URLProtocol.registerClass(HermeticURLProtocol.self)
        }

        override class func canInit(with request: URLRequest) -> Bool {
            // W-RECONCILE Sec-L1 — scope interception to the seeded host so even a
            // mis-set `-uitest-hermetic` arg can't blanket-intercept all traffic
            // from fixtures. Defence-in-depth (whole file is `#if DEBUG`).
            guard HermeticUITestSupport.isActive else { return false }
            return request.url?.host == HermeticUITestSupport.seededHost
        }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest {
            request
        }

        override func startLoading() {
            let path = request.url?.path ?? "/"
            // Phase 08 — the document filter contract is about *which* answer is
            // on screen, so the fixture router needs the query, not just the
            // path. Everything without a Phase-8 scenario resolves exactly as
            // before through the same path-keyed table.
            let (status, body) = HermeticFixtures.response(
                forPath: path,
                method: request.httpMethod ?? "GET",
                query: request.url.flatMap {
                    URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems
                } ?? []
            )
            let fallbackURL = URL(string: HermeticUITestSupport.seededBaseURL) ?? URL(fileURLWithPath: "/")
            let url = request.url ?? fallbackURL
            guard let response = HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            ) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }
#endif
