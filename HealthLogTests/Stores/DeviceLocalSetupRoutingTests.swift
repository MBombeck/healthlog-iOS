// Diese Suite liest App-Target-Symbole (`HKReadinessStore`, `OnboardingFlow`),
// die in der SPM-Library nicht enthalten sind. Der SPM-Test-Build überspringt
// die Datei — dieselbe Konvention wie `HKReadinessStoreTests`.
#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing

    /// **Phase 16 Plan 01 — K10: an account flag decides device-local setup.**
    ///
    /// The walkthrough's fresh install greeted the operator with "Apple Health
    /// nicht verbunden" on the dashboard. The HealthKit step exists and works;
    /// it was never shown. `onboardingTourCompleted` is an **account** fact —
    /// the web onboarding sets it too — and 08-08 made it the sole gate on the
    /// post-authentication route, so a completed account is handed straight to
    /// the shell. HealthKit authorization is a **device** fact. An account flag
    /// gating a device resource is the whole defect, and it is invisible to
    /// every existing test because both halves are individually correct.
    ///
    /// The split this suite pins: device-local steps (HealthKit, notifications)
    /// run on a device that has not done them, whatever the account says;
    /// account-level steps (AI source, anamnesis, baseline profile) keep
    /// honouring the account flag, so a returning user is never re-onboarded.
    ///
    /// Source contracts read comment-stripped source — a doc comment naming a
    /// symbol is not the symbol.
    @MainActor
    @Suite("Phase 16 device-local setup routing")
    struct DeviceLocalSetupRoutingTests {
        // MARK: - RED

        /// A completed account signing in on a device that never showed the
        /// HealthKit sheet must get the device-local half of setup.
        ///
        /// Everything this case asserts is measured through published surface:
        /// the device's own readiness store truthfully reports "never asked",
        /// and the production route is read for whether anything consults it.
        @Test("a completed account on a fresh device is still asked for the device-local half")
        func freshDeviceGetsDeviceLocalSetup() throws {
            // The device fact, from the store that owns it. A fresh install has
            // no `requestedAt` for this user, so the device is honest about
            // owing the sheet — this is the signal the route ignores.
            let readiness = try Self.readinessStore(hasRequestedAuthorization: false)
            #expect(
                !readiness.hasEverRequestedAuthorization,
                "a device that never showed the sheet must say so"
            )
            // And the same fact, said the way the connection state says it —
            // `.notRequested` is exactly "this device never saw the sheet",
            // computed without any HealthKit host being present.
            #expect(
                HKReadinessStore.computeState(statuses: [:], hasRequestedAuthorization: false)
                    == .notRequested
            )

            // The account fact, unchanged: the server calls this account done.
            #expect(
                PostAuthenticationRouteResolver.resolve(server: .completed, cache: .absent)
                    == .authenticatedShell,
                "08-08's account-level answer stands; this plan does not overturn it"
            )

            var violations: [String] = []
            let resolver = try Self.strippedSource(Self.resolverPath)
            if !resolver.contains("deviceLocal") {
                violations.append(
                    "the post-authentication decision takes no device-local input at all"
                )
            }
            let flow = try Self.flowPaths.map { try Self.strippedSource($0) }.joined(separator: "\n")
            if !flow.contains("hasEverRequestedAuthorization") {
                violations.append(
                    "the flow reaches the shell without ever asking this device what it has done"
                )
            }
            if !flow.contains("case deviceLocal") {
                violations.append(
                    "no step says whether it configures this device or this account — the classification does not exist"
                )
            }

            #expect(
                violations.isEmpty,
                "EXPECTED_RED: an account flag skips device-local setup on a device that never granted anything"
            )
        }

        // MARK: - GREEN — the decision, and the route it opens

        /// The narrowed decision, in full. Only one cell moves relative to
        /// 08-08, and it is the cell K10 was reported against.
        @Test("the scope decision narrows a finished account by exactly one question")
        func setupScopeMatrixIsTotal() {
            let expected: [ScopeRow] = [
                // A finished account owes only what this handset owes.
                ScopeRow(account: true, device: .outstanding, scope: .deviceLocalOnly),
                ScopeRow(account: true, device: .complete, scope: .none),
                // An unreadable device signal is never turned into setup work.
                ScopeRow(account: true, device: .unknown, scope: .none),
                // An unfinished account owes everything, device half included.
                ScopeRow(account: false, device: .outstanding, scope: .full),
                ScopeRow(account: false, device: .complete, scope: .full),
                ScopeRow(account: false, device: .unknown, scope: .full)
            ]
            #expect(
                expected.count == 2 * DeviceLocalSetupState.allCases.count,
                "every device answer needs both account answers"
            )
            for row in expected {
                #expect(
                    PostAuthenticationRouteResolver.setupScope(
                        accountSetupComplete: row.account,
                        deviceLocalSetup: row.device
                    ) == row.scope,
                    "account=\(row.account) device=\(row.device.rawValue) must resolve to \(row.scope.rawValue)"
                )
            }
        }

        /// Every step answers the question, and the two device-local ones are
        /// the two that cannot be finished on another handset.
        @Test("each step says which resource it configures, and only two are device-local")
        func stepScopeClassificationIsExhaustive() {
            #expect(OnboardingFlow.Step.healthKit.scope == .deviceLocal)
            #expect(OnboardingFlow.Step.notifications.scope == .deviceLocal)
            for step in [OnboardingFlow.Step.aiSource, .anamnesis, .baselineProfile, .auth, .serverURL] {
                #expect(step.scope == .accountLevel, "\(step) belongs to the account, not the handset")
            }
            for step in [OnboardingFlow.Step.checkingCompletion, .completionUnavailable, .done] {
                #expect(step.scope == .transient, "\(step) is not a place in the route")
            }
        }

        /// The route a device-local-only run walks: the head, and nothing else.
        /// The tail 08-08 skipped stays skipped — this is the clause that keeps
        /// the fix from becoming "full onboarding for returning users".
        @Test("a device-local-only run walks the head and never the account-level tail")
        func deviceLocalRouteExcludesTheAccountLevelTail() {
            let route = OnboardingFlow.activeRoute(
                chosenMode: .server,
                standaloneModeAvailable: false,
                setupScope: .deviceLocalOnly
            )
            #expect(route == [.healthKit, .notifications])
            for step in [OnboardingFlow.Step.aiSource, .anamnesis, .baselineProfile, .auth, .serverURL, .welcome] {
                #expect(!route.contains(step), "\(step) must not be replayed for a completed account")
            }

            // And the bar counts the route actually walked, not the one that
            // was skipped: "Schritt 1 von 2", not "Schritt 5 von 7".
            let progress = OnboardingFlow.progress(
                for: .healthKit,
                chosenMode: .server,
                standaloneModeAvailable: false,
                setupScope: .deviceLocalOnly
            )
            #expect(progress.total == 2)
            #expect(progress.position == 1)

            // The post-auth boundary is unchanged: no back tap walks a
            // signed-in user back across their own login.
            #expect(OnboardingFlow.previousStep(
                from: .healthKit,
                chosenMode: .server,
                standaloneModeAvailable: false,
                setupScope: .deviceLocalOnly
            ) == nil)
            #expect(OnboardingFlow.previousStep(
                from: .notifications,
                chosenMode: .server,
                standaloneModeAvailable: false,
                setupScope: .deviceLocalOnly
            ) == .healthKit)
        }

        /// The default is the old behaviour, spelled out: every caller that does
        /// not name a scope gets the full route it got before this plan.
        @Test("the full route is unchanged for every caller that names no scope")
        func fullRouteIsUnchangedByDefault() {
            for mode in [OnboardingMode.server, .standalone] {
                for available in [true, false] {
                    #expect(
                        OnboardingFlow.activeRoute(
                            chosenMode: mode,
                            standaloneModeAvailable: available
                        ) == OnboardingFlow.activeRoute(
                            chosenMode: mode,
                            standaloneModeAvailable: available,
                            setupScope: .full
                        )
                    )
                }
            }
        }

        // MARK: - Controls (green before and after)

        /// The case 08-08 was built for, and it must survive intact: a device
        /// that HAS been through the sheet is not sent back through it.
        @Test("a completed account on a device that already did the local half goes straight to the shell")
        func completedDeviceRoutesStraightToTheShell() throws {
            let readiness = try Self.readinessStore(hasRequestedAuthorization: true)
            #expect(readiness.hasEverRequestedAuthorization)
            #expect(
                PostAuthenticationRouteResolver.resolve(server: .completed, cache: .absent)
                    == .authenticatedShell
            )
        }

        /// An account whose setup is genuinely outstanding walks the whole
        /// route, device-local and account-level alike. The decoupling narrows
        /// what a *completed* account is asked for; it must not widen anything.
        @Test("an account the server calls incomplete still walks the full route")
        func incompleteAccountWalksFullOnboarding() {
            #expect(
                PostAuthenticationRouteResolver.resolve(server: .incomplete, cache: .absent) == .setup
            )
            let route = OnboardingFlow.activeRoute(chosenMode: .server, standaloneModeAvailable: false)
            for step in [OnboardingFlow.Step.healthKit, .notifications, .aiSource, .anamnesis, .baselineProfile] {
                #expect(route.contains(step), "the full route still contains \(step)")
            }
        }

        /// Ambiguity keeps its own answer. A device-local decision may never be
        /// reached by guessing at an account-level one that did not resolve.
        @Test("an unresolved completion lookup is still retried, not routed")
        func ambiguityStillRetries() {
            #expect(
                PostAuthenticationRouteResolver.resolve(server: .unavailable, cache: .absent)
                    == .retryCompletionLookup
            )
        }

        // MARK: - Helpers

        /// One cell of the scope decision. A named row rather than a tuple so
        /// the two booleans in it can never be read in the wrong order.
        private struct ScopeRow {
            let account: Bool
            let device: DeviceLocalSetupState
            let scope: PostAuthenticationSetupScope
        }

        private static let resolverPath = "HealthLog/Stores/PostAuthenticationRouteResolver.swift"
        /// The flow's own sources. Two files, by the same 600-line discipline
        /// that already produced `OnboardingRouteProgress.swift` — the route is
        /// a value and lives beside the view that walks it, so a contract about
        /// "the flow" has to read both or it can be satisfied by a move.
        private static let flowPaths = [
            "HealthLog/Screens/Onboarding/OnboardingFlow.swift",
            "HealthLog/Screens/Onboarding/OnboardingFlowRoute.swift"
        ]

        /// A readiness store on isolated defaults, standing for a device that
        /// has (or has not) already been through the system sheet.
        private static func readinessStore(hasRequestedAuthorization: Bool) throws -> HKReadinessStore {
            let name = "test.deviceLocalSetup.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: name))
            defaults.removePersistentDomain(forName: name)
            let keychain = InMemoryKeychain()
            try keychain.setString("owner-a", forKey: KeychainKey.userID)
            let store = HKReadinessStore(
                healthKit: nil,
                backgroundSync: StubBackgroundSyncCoordinator(),
                keychain: keychain,
                defaults: defaults
            )
            if hasRequestedAuthorization { store.markAuthorizationRequested() }
            return store
        }

        // MARK: - Source access

        private static let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        private static func strippedSource(_ relativePath: String) throws -> String {
            let text = try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
            return stripLineComments(from: stripBlockComments(from: text))
        }

        private static func stripBlockComments(from source: String) -> String {
            var out = ""
            var rest = Substring(source)
            while let open = rest.range(of: "/*") {
                out += rest[..<open.lowerBound]
                guard let close = rest.range(of: "*/", range: open.upperBound ..< rest.endIndex) else { return out }
                rest = rest[close.upperBound...]
            }
            return out + rest
        }

        private static func stripLineComments(from source: String) -> String {
            source.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
                var quoted = false
                var previous: Character = " "
                for (offset, character) in line.enumerated() {
                    if character == "\"", previous != "\\" { quoted.toggle() }
                    if !quoted, character == "/", previous == "/" { return String(line.prefix(offset - 1)) }
                    previous = character
                }
                return String(line)
            }.joined(separator: "\n")
        }
    }

#endif
