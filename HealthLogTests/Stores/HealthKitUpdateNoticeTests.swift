// Diese Suite liest App-Target-Symbole (`HKReadinessStore`, `HealthKitService`,
// `FreshInstallGuard`), die in der SPM-Library nicht enthalten sind. Der
// SPM-Test-Build überspringt die Datei.
#if !SWIFT_PACKAGE

    import Foundation
    #if canImport(HealthKit)
        import HealthKit
    #endif
    @testable import HealthLog
    import Testing

    /// **Phase 25 Plan 01 — decision E-2026-08-28: the update-notice card.**
    ///
    /// The operator's wife updated to the newest build on a device that had
    /// HealthLog before. Apple Health was not connected at all, and nothing in
    /// the app told her. The mechanism is 12-12's latch: any authorization
    /// request ever made writes `hl.healthkit.requestedAt.<token>`,
    /// `isConnected` answers `true` for every non-`.denied` state, and
    /// `shouldShowDashboardBanner` refuses on that FIRST — permanently. The
    /// banner's rule is deliberate (K10) and pinned by 12-12; it does not move
    /// here. What this suite demands is a card with its OWN rule.
    ///
    /// **Every starting state below is a realistic pre-existing installation**
    /// — the repository's standing rule, paid for twice (the b171 workout-read
    /// mask, the 13-05 sentinel wipe): a fresh install passes everything and
    /// proves nothing, because the regression that matters can only happen to
    /// a device already in the field.
    @MainActor
    @Suite("Phase 25 update notice — the card that tells an existing install what changed")
    struct HealthKitUpdateNoticeTests {
        #if canImport(HealthKit)

            // MARK: - RED — three pre-existing installations, one absent card

            /// **State one — the field observation.** `requestedAt` is SET
            /// (the sheet ran once, or the banner CTA was tapped once, or the
            /// 12-12 migration self-heal fired), nothing was ever granted,
            /// nothing ever synced. `isConnected` is `true` through
            /// `hasEverRequestedAuthorization`, so the banner is latched down
            /// — correctly, per K10, and pinned here as a CONTROL — and the
            /// dashboard offers no connect affordance at all. That absence is
            /// the RED.
            @Test("requestedAt latched + nothing granted → the connect card, beside a still-silent banner")
            func wifeStateRequestedAtLatchedNothingGrantedShowsTheConnectCard() async throws {
                let install = try Self.preExistingInstall()
                let store = try Self.readinessStore(install: install)
                store.markAuthorizationRequested()
                await store.refresh()

                // The dead end, pinned exactly as found: write proxy says
                // partially granted (all types missing), banner stays down.
                guard case .partiallyGranted = store.state else {
                    Issue.record("expected .partiallyGranted for the latched never-granted install, got \(store.state)")
                    return
                }
                #expect(store.isConnected, "the requestedAt latch makes isConnected true — the mechanism 12-12 established")
                #expect(
                    !store.shouldShowDashboardBanner,
                    "the banner's suppression is CORRECT (K10) and pinned by 12-12 — it must not move to fix this"
                )

                // This install was updated: the launch prologue saw the
                // sentinel an older build wrote.
                HealthKitUpdateNotice.recordLaunch(outcome: .returningInstall, defaults: install.defaults)

                let variant = HealthKitUpdateNotice.visibleVariant(
                    state: store.state,
                    statuses: store.writeAuthorizationStatuses,
                    defaults: install.defaults
                )
                #expect(
                    variant == .connect,
                    "EXPECTED_RED: 25-01 state one — requestedAt latched, nothing granted, and the dashboard offers no way in"
                )
            }

            /// **State two — never asked at all.** No `requestedAt`, nothing
            /// granted (a re-login under a fresh partition token, or an
            /// onboarding that never reached the HealthKit step). The banner
            /// DOES show here — pinned as a control — but the one-time update
            /// announcement is owed regardless: the card's arming must not
            /// secretly depend on the `requestedAt` latch in either direction.
            @Test("never asked, no requestedAt → the connect card, beside the banner that already shows")
            func neverAskedInstallShowsTheConnectCard() async throws {
                let install = try Self.preExistingInstall()
                let store = try Self.readinessStore(install: install)
                await store.refresh()

                #expect(store.state == .notRequested)
                #expect(
                    store.shouldShowDashboardBanner,
                    "control: with no latch the banner shows — this state is NOT the dead end, and it stays that way"
                )

                HealthKitUpdateNotice.recordLaunch(outcome: .returningInstall, defaults: install.defaults)

                let variant = HealthKitUpdateNotice.visibleVariant(
                    state: store.state,
                    statuses: store.writeAuthorizationStatuses,
                    defaults: install.defaults
                )
                #expect(
                    variant == .connect,
                    "EXPECTED_RED: 25-01 state two — never asked, and the update announcement never appears"
                )
            }

            /// **State three — D-16-03-A's install.** Granted everything the
            /// OLD sheet asked for, missing exactly the State-of-Mind write E2
            /// added, data demonstrably flowing (`lastSyncedAt` set). The
            /// banner stays down (control, K10). Today the only route to the
            /// enlarged set is the Settings reconnect row nobody found; the
            /// card must say "new: ECG and mood" — and neither `isConnected`
            /// nor the sync truth may suppress it.
            @Test("partially connected, syncing → the new-types card, not the connect card")
            func partiallyConnectedInstallShowsTheNewTypesCard() async throws {
                let install = try Self.preExistingInstall()
                var statuses: [String: HKReadinessStore.AuthStatus] = [:]
                for identifier in HealthKitService.defaultWriteTypes.map(\.identifier) {
                    statuses[identifier] = .sharingAuthorized
                }
                statuses[Self.stateOfMindIdentifier] = .notDetermined
                let store = try Self.readinessStore(install: install, statuses: statuses)
                store.markAuthorizationRequested()
                store.noteSuccessfulSync(at: Date(timeIntervalSince1970: 1_756_339_200))
                await store.refresh()

                guard case let .partiallyGranted(missing) = store.state else {
                    Issue.record("expected .partiallyGranted for the old-set install, got \(store.state)")
                    return
                }
                #expect(missing == [Self.stateOfMindIdentifier], "exactly the newly-asked type is missing")
                #expect(store.isConnected)
                #expect(
                    !store.shouldShowDashboardBanner,
                    "control: the banner stays down for a connected install — K10, pinned by 16-03"
                )

                HealthKitUpdateNotice.recordLaunch(outcome: .returningInstall, defaults: install.defaults)

                let variant = HealthKitUpdateNotice.visibleVariant(
                    state: store.state,
                    statuses: store.writeAuthorizationStatuses,
                    defaults: install.defaults
                )
                #expect(
                    variant == .newTypes,
                    "EXPECTED_RED: 25-01 state three — partially connected, and the new-types card never appears"
                )
            }

            /// The rule can be right and the screen still empty. The dashboard
            /// must actually render the card — exactly once, beside the banner
            /// call site whose latch it supersedes.
            @Test("the dashboard renders the update-notice card exactly once")
            func theDashboardCarriesTheUpdateNoticeCard() throws {
                let source = try FirstSheetTypeSetTests.strippedSource(Self.dashboardScreenPath)
                let callSites = source.components(separatedBy: "HealthKitUpdateNoticeCard(").count - 1
                #expect(
                    callSites == 1,
                    "EXPECTED_RED: 25-01 the dashboard carries no update-notice card"
                )
            }

            // MARK: - The fresh install, the ✕, and the connect that ends it

            /// A fresh install must never see the card — even when onboarding
            /// is skipped. The disarm is recorded at launch, from the
            /// prologue's own `.freshInstall` verdict, before any onboarding
            /// runs; and a later `.returningInstall` launch (the second launch
            /// of the same install) must not overturn it: the decision is
            /// taken once per install.
            @Test("a fresh install never sees the card, even when onboarding is skipped")
            func aFreshInstallNeverSeesTheCard() async throws {
                let install = try Self.preExistingInstall()
                let store = try Self.readinessStore(install: install)
                await store.refresh()
                #expect(store.state == .notRequested, "onboarding skipped: no request ever ran")

                HealthKitUpdateNotice.recordLaunch(
                    outcome: .freshInstall(wipedInheritedServerIdentity: false),
                    defaults: install.defaults
                )
                let firstLaunch = HealthKitUpdateNotice.visibleVariant(
                    state: store.state,
                    statuses: store.writeAuthorizationStatuses,
                    defaults: install.defaults
                )
                #expect(firstLaunch == nil, "the fresh-install verdict disarms the card before onboarding can be skipped")

                HealthKitUpdateNotice.recordLaunch(outcome: .returningInstall, defaults: install.defaults)
                let secondLaunch = HealthKitUpdateNotice.visibleVariant(
                    state: store.state,
                    statuses: store.writeAuthorizationStatuses,
                    defaults: install.defaults
                )
                #expect(
                    secondLaunch == nil,
                    "the second launch of a fresh install is .returningInstall — the recorded decision wins, forever"
                )
            }

            /// The ✕ is per install and permanent: the same defaults read
            /// again (a relaunch) still answers "dismissed".
            @Test("dismissal persists across relaunch and the card never returns")
            func dismissalPersistsAcrossRelaunch() async throws {
                let install = try Self.preExistingInstall()
                let store = try Self.readinessStore(install: install)
                store.markAuthorizationRequested()
                await store.refresh()
                HealthKitUpdateNotice.recordLaunch(outcome: .returningInstall, defaults: install.defaults)

                HealthKitUpdateNotice.markDismissed(in: install.defaults)

                // "Relaunch": nothing in memory, only the persisted keys.
                #expect(HealthKitUpdateNotice.isDismissed(in: install.defaults))
                let variant = HealthKitUpdateNotice.visibleVariant(
                    state: store.state,
                    statuses: store.writeAuthorizationStatuses,
                    defaults: install.defaults
                )
                #expect(variant == nil, "one ✕, persisted per install — the card never returns")
            }

            /// A successful connect ends the card without the ✕: the card is
            /// rendered from the readiness state, and `.fullyGranted` warrants
            /// nothing.
            @Test("a successful connect clears the card without needing the ✕")
            func aSuccessfulConnectClearsTheCardWithoutDismissal() async throws {
                let install = try Self.preExistingInstall()
                var statuses: [String: HKReadinessStore.AuthStatus] = [:]
                for identifier in HealthKitService.defaultWriteTypes.map(\.identifier) {
                    statuses[identifier] = .sharingAuthorized
                }
                let store = try Self.readinessStore(install: install, statuses: statuses)
                store.markAuthorizationRequested()
                await store.refresh()
                #expect(store.state == .fullyGranted)

                HealthKitUpdateNotice.recordLaunch(outcome: .returningInstall, defaults: install.defaults)
                #expect(!HealthKitUpdateNotice.isDismissed(in: install.defaults), "no ✕ was tapped")
                let variant = HealthKitUpdateNotice.visibleVariant(
                    state: store.state,
                    statuses: store.writeAuthorizationStatuses,
                    defaults: install.defaults
                )
                #expect(variant == nil, "the grant itself removes the card — no dismissal needed")
            }

            // MARK: - The arming decision, pinned

            /// The pre-b267 update path arms too: an install whose first
            /// launch of this build reads `.preexistingInstall` (no sentinel
            /// yet, but the 13-05 witnesses answer) is exactly as updated as
            /// a `.returningInstall`. And a prologue composed without the
            /// guard (`nil`) records nothing — no decision means no card,
            /// the fail-closed direction.
            @Test("preexisting-install evidence arms; a guardless prologue decides nothing")
            func theArmingDecisionCoversBothUpdateShapes() async throws {
                let updated = try Self.preExistingInstall()
                HealthKitUpdateNotice.recordLaunch(
                    outcome: .preexistingInstall(witness: .defaultsKeyOlderThanTheSentinel),
                    defaults: updated.defaults
                )
                #expect(HealthKitUpdateNotice.arming(in: updated.defaults) == .armed)

                let undecided = try Self.preExistingInstall()
                HealthKitUpdateNotice.recordLaunch(outcome: nil, defaults: undecided.defaults)
                #expect(
                    HealthKitUpdateNotice.arming(in: undecided.defaults) == nil,
                    "no verdict, no decision — and no decision shows no card"
                )
                let store = try Self.readinessStore(install: undecided)
                await store.refresh()
                let variant = HealthKitUpdateNotice.visibleVariant(
                    state: store.state,
                    statuses: store.writeAuthorizationStatuses,
                    defaults: undecided.defaults
                )
                #expect(variant == nil)
            }

            // MARK: - Source contracts: the seams that keep pinned worlds pinned

            /// The hermetic UI-test worlds must not gain a card no seed
            /// planted: 12-12 made `testFocusedAccessibilityAudit`'s subject
            /// reproducible by purging exactly the residue that decided it,
            /// and a reused simulator's install sentinel is residue of the
            /// same shape. Both hermetic seeds and the onboarding-walkthrough
            /// seam record the disarm; the app's own init records the launch
            /// decision. Comment-stripped source — a doc comment naming a
            /// symbol is not the symbol.
            /// NOTE on the stripper: `FirstSheetTypeSetTests.strippedSource`
            /// treats a `/*` inside a doc comment as a block opener, and
            /// `HermeticUITestSupport.swift` writes `/api/insights/*` in one —
            /// everything below it would vanish from the scan. These two
            /// files are read with a line-comment strip instead, which is the
            /// half of the house rule that matters here (a `//` line naming a
            /// symbol is not the symbol).
            @Test("every UI-test seed disarms the card, and the app's init records the launch decision")
            func theSeamsDisarmAndTheInitRecords() throws {
                var violations: [String] = []

                let hermetic = try Self.lineStrippedSource(Self.hermeticSupportPath)
                if let purge = FirstSheetTypeSetTests.member(
                    named: "private static func purgePermissionPromptingResidue",
                    in: hermetic
                ) {
                    if !purge.contains("HealthKitUpdateNotice.disarm()") {
                        violations.append("the hermetic residue purge does not disarm the update notice")
                    }
                } else {
                    violations.append("purgePermissionPromptingResidue is gone — the hermetic seed lost its purge")
                }

                let app = try Self.lineStrippedSource(Self.healthLogAppPath)
                if !app.contains("HealthKitUpdateNotice.recordLaunch(outcome: prologue.freshInstall") {
                    violations.append("HealthLogApp.init does not record the launch decision from the prologue's ledger")
                }
                let skipBootstrapDisarms = app.range(
                    of: #"-uitest-skip-bootstrap[\s\S]*?HealthKitUpdateNotice\.disarm\(\)"#,
                    options: .regularExpression
                ) != nil
                if !skipBootstrapDisarms {
                    violations.append("the -uitest-skip-bootstrap walkthrough seam does not disarm the update notice")
                }

                #expect(violations.isEmpty, Comment(rawValue: violations.joined(separator: "; ")))
            }

            /// The card's CTA is the banner's own connect flow and nothing
            /// else: one `requestAuthorization()` call over the default sets.
            /// No second authorization path rides in with it — the medication
            /// type's per-object toggle stays the only one (the SIGABRT
            /// fence), and because the card changes no set, the 5.1.3(i)
            /// transparency page derives exactly what it derived before.
            @Test("the card's CTA is the shared connect flow, and no other authorization path")
            func theCardCTASharesTheConnectFlow() throws {
                let card = try FirstSheetTypeSetTests.strippedSource(Self.cardComponentPath)
                let ctaCalls = card.components(separatedBy: "readiness.requestAuthorization()").count - 1
                #expect(ctaCalls == 1, "exactly one CTA action, and it is the banner's own recovery path")
                #expect(
                    !card.contains("requestPerObjectReadAuthorization"),
                    "the medication type's only legal path stays the settings toggle — the documented SIGABRT"
                )
                #expect(
                    !card.contains("requestMoodAuthorization") && !card.contains("requestEcgAuthorizationIfNeeded"),
                    "no side-channel authorization call rides in with the card"
                )
            }

            // MARK: - Fixtures: a realistic pre-existing installation

            static let stateOfMindIdentifier = HKObjectType.stateOfMindType().identifier

            struct PreExistingInstall {
                let defaults: UserDefaults
                let keychain: InMemoryKeychain
            }

            /// The starting point every case shares: a device that has run
            /// older builds. Its defaults carry what older builds wrote
            /// (the `hl.syncMode` a paired bootstrap persists, the 13-05
            /// sentinel), and its Keychain carries a signed-in user — the
            /// population that owns the observation.
            static func preExistingInstall() throws -> PreExistingInstall {
                let name = "test.updateNotice.\(UUID().uuidString)"
                let defaults = try #require(UserDefaults(suiteName: name))
                defaults.removePersistentDomain(forName: name)
                defaults.set("paired", forKey: "hl.syncMode")
                defaults.set(FreshInstallGuard.sentinelValue, forKey: FreshInstallGuard.sentinelDefaultsKey)
                let keychain = InMemoryKeychain()
                try keychain.setString("owner-a", forKey: KeychainKey.userID)
                return PreExistingInstall(defaults: defaults, keychain: keychain)
            }

            /// A readiness store over a stub service whose write statuses are
            /// the fixture's — `.notDetermined` across the whole default write
            /// set unless a case says otherwise, which is exactly what Apple
            /// reports for a device that was never granted anything.
            static func readinessStore(
                install: PreExistingInstall,
                statuses: [String: HKReadinessStore.AuthStatus]? = nil
            ) throws -> HKReadinessStore {
                var resolved = statuses ?? [:]
                if statuses == nil {
                    for identifier in HealthKitService.defaultWriteTypes.map(\.identifier) {
                        resolved[identifier] = .notDetermined
                    }
                }
                return HKReadinessStore(
                    healthKit: StubStatusService(statuses: resolved),
                    backgroundSync: StubBackgroundSyncCoordinator(),
                    keychain: install.keychain,
                    defaults: install.defaults
                )
            }

        #endif

        static let dashboardScreenPath = "HealthLog/Screens/Dashboard/DashboardScreen.swift"
        static let hermeticSupportPath = "HealthLog/App/HermeticUITestSupport.swift"
        static let healthLogAppPath = "HealthLog/App/HealthLogApp.swift"
        static let cardComponentPath = "HealthLog/Components/HealthKitUpdateNoticeCard.swift"

        /// Source with `//`-comment lines removed (leading-trimmed), quotes
        /// respected within a line. Used where the shared block stripper
        /// would truncate on a `/*` inside a doc comment.
        static func lineStrippedSource(_ relativePath: String) throws -> String {
            let root = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let text = try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
            return text.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
        }
    }

    #if canImport(HealthKit)

        /// Minimal `HealthKitServiceProtocol` double that reports a fixed
        /// status dictionary — the shape `refresh()` actually consumes.
        /// Template: `StubDeniedWriteService` in `HKReadinessStoreTests`.
        private final class StubStatusService: HealthKitServiceProtocol, @unchecked Sendable {
            private let statuses: [String: HKReadinessStore.AuthStatus]

            init(statuses: [String: HKReadinessStore.AuthStatus]) {
                self.statuses = statuses
            }

            // MARK: Capability + status

            func isAvailable() -> Bool {
                true
            }

            func authorizationStatus(for _: HKObjectType) -> HKAuthorizationStatus {
                .notDetermined
            }

            func authorizationStatuses(for _: Set<HKSampleType>) -> [String: HKReadinessStore.AuthStatus] {
                statuses
            }

            // MARK: Authorization

            func requestAuthorization(read _: Set<HKObjectType>, write _: Set<HKSampleType>) async throws {}
            func resetAuthDisabledTypes() async {}

            func defaultReadTypes() -> Set<HKObjectType> {
                [HKQuantityType(.bodyMass)]
            }

            func defaultWriteTypes() -> Set<HKSampleType> {
                [HKQuantityType(.bodyMass)]
            }

            // MARK: Direct write + observation

            func writeMeasurement(_: HealthLog.Measurement) async throws {}
            func writeMoodEntry(_: MoodEntry) async throws {}
            func startBackgroundDeliveries() async throws {}

            // MARK: AnyHealthKitWriter required slice (no extension defaults)

            func write(_: HealthLog.Measurement) async throws {}
            func writeMood(_: MoodEntry) async throws {}
            func deleteMood(id _: String) async throws {}
            func requestMoodAuthorization() async throws {}
            func startMoodImport(repo _: MoodRepository, userID _: String?) async {}
            func stopMoodImport() async {}
            func resetMoodImport() async {}
            func activateBackgroundDeliveries() async throws {}
            func runBackgroundSyncPass() async {}
            func attachUploader(_: MeasurementBatchUploader) async {}
            func attachDeletionReconciler(_: MeasurementDeletionReconciler) async {}
            func setInitialBackfillCutoff(_: Date?) async {}
            func attachFeatureFlags(_: (any FeatureFlagsServicing)?) async {}
        }

    #endif

#endif
