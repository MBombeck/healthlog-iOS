// Diese Suite hängt an `AppContainer` (App-Target-only) — im SPM-Library-Build
// gibt es keinen AppContainer, also wird die Datei dort übersprungen.
#if !SWIFT_PACKAGE

    import Foundation
    import Testing
    #if canImport(AuthenticationServices)
        import AuthenticationServices
    #endif
    @testable import HealthLog

    /// **v0.14.8 W3 (AUDIT-SECURITY-B175) — logout-cleanup completeness.**
    ///
    /// The audit found the third recurrence of the same leak class (mood →
    /// workout → cycle): a per-user store/importer is added to `AppContainer`
    /// but never wired into `performFullLocalLogout`, so the next user on the
    /// same device inherits the previous user's state. This suite pins:
    ///
    /// 1. **H-1** — the cycle HK import observer + per-user anchors are reset
    ///    on logout (`CycleStore.deactivateOnLogout` →
    ///    `resetCycleImportObserver`), mirroring the existing mood/workout
    ///    anchor resets.
    /// 2. **M-1 registry** — every store-typed `AppContainer` property must be
    ///    explicitly classified as reset-on-logout or intentionally exempt. A
    ///    NEW store property fails the reflection test until its author makes
    ///    the logout decision — the structural fix for the recurring pattern.
    /// 3. **M-1/M-3 behaviour** — the newly wired stores actually reset
    ///    (in-memory drafts/config + the `hl.delivery.*` UserDefaults residue).
    ///
    /// `.serialized` because the behavioural tests go through `.standard`
    /// UserDefaults (the container hardwires it) — parallel runs would race on
    /// the seeded keys.
    @MainActor
    @Suite("Logout completeness — AUDIT-SECURITY-B175", .serialized)
    struct LogoutCompletenessTests {
        // MARK: - H-1: Cycle importer + anchors reset on logout

        /// The cycle importer must be stopped + its per-user anchors reset on
        /// EVERY logout path — otherwise the observer keeps uploading the
        /// device's HK cycle samples under the NEXT user's token (cross-user
        /// mis-attribution of the highest-sensitivity data category).
        @Test("logout resets the cycle HK import observer + anchors (H-1)")
        func logoutResetsCycleImportObserver() async throws {
            let writer = MockHealthKitWriter()
            let container = try makeContainer(
                keychain: InMemoryKeychain(),
                healthKit: writer
            )
            #expect(writer.resetCycleImportCallCount == 0)

            await container.performFullLocalLogout(reason: .userInitiated)

            #expect(
                writer.resetCycleImportCallCount == 1,
                "performFullLocalLogout MUST call cycleStore.deactivateOnLogout() → resetCycleImportObserver()"
            )
        }

        /// The in-memory cycle surfaces (calendar / predictions / profile) are
        /// container-lifetime — without the reset the previous user's
        /// menstrual-cycle data renders until process death.
        @Test("logout drops the in-memory cycle state (H-1)")
        func logoutDropsInMemoryCycleState() async throws {
            let container = try makeContainer(
                keychain: InMemoryKeychain(),
                healthKit: MockHealthKitWriter()
            )

            await container.performFullLocalLogout(reason: .userInitiated)

            let cycle = container.cycleStore
            #expect(cycle.calendar == nil)
            #expect(cycle.cycles.isEmpty)
            #expect(cycle.stats == nil)
            #expect(cycle.profile == nil)
            #expect(cycle.prediction == nil)
            #expect(cycle.offlinePrediction == nil)
            #expect(cycle.lastError == nil)
            #expect(cycle.isDisabled == false)
        }

        // MARK: - M-1: Registry — no store may skip the logout decision

        /// Store-typed `AppContainer` properties that ARE reset by
        /// `performFullLocalLogout` (via `clearOnLogout()`,
        /// `deactivateOnLogout()`, the `ServerStatsStores.clearOnLogout()`
        /// bundle, or — for `aiConsentStore` — the per-provider
        /// `revoke(for:)` / `revokeAllBYO()` calls).
        ///
        /// ⚠️ Adding a name here REQUIRES the matching call in
        /// `AppContainer+Logout.performFullLocalLogout` — the registry can
        /// only enforce that the classification decision was made.
        private static let resetOnLogout: Set<String> = [
            "customMetricsStore", // Build 3 — PHI: eigene Metriken + Werte
            "accountSecurityStore", // parity 2.1 — clearOnLogout in cascade (LogoutClearable)
            "achievementsStore", "aiConsentStore", "aiProviderStore",
            "allergiesStore", // v1.25 PHI — clearOnLogout in cascade
            "familyHistoryStore", // v1.25 PHI — clearOnLogout in cascade
            "avatarStore", "chartsStore", "coachNudgeStore", // coachNudge: clearOnLogout in cascade
            "coachCadenceSuggestionsStore", // #30 — clearOnLogout in cascade
            "cycleStore", "dailyBriefingStore",
            "dashboardLayoutStore", "dashboardStore",
            "deliveryPreferencesStore", "diabetesStore", // diabetes: clearOnLogout in cascade
            "disclaimerAckStore", // DISC-02 — clearOnLogout in cascade
            "doctorReportStore",
            "documentsStore", // PHI — clearOnLogout in cascade (LogoutClearable)
            // GH #74 — deactivateOnLogout (explicit async path, like
            // `moodHealthSyncStore`): forces the ECG upload switch OFF and
            // clears the per-user HealthKit cursor, so the next user on this
            // device inherits neither the consent nor the stream position.
            "ecgHealthSyncStore",
            "featureFlagsStore",
            "fitbitIntegrationStore", // v1.18.7 web-parity — clearOnLogout in cascade
            "healthScoreStore", "hkReadinessStore",
            "illnessStore", // v1.18.6 PHI — clearOnLogout in cascade
            "injectionSitePrefsStore", "insightsLayoutStore", "insightsStore",
            "labsStore", // v1.18.6 PHI — clearOnLogout in cascade
            "liveHealthKitTodayStore", "localDoctorReportStore",
            "measurementRemindersStore", // v0.15 W-FRONTDOORS — clearOnLogout in cascade
            "measurementsStore",
            "medicationHealthSyncStore", // deactivateOnLogout (explicit async path, like moodHealthSyncStore)
            "medicationsStore",
            "mentalHealthStore", // v1.25 PHI — clearOnLogout in cascade
            // parity 2.3 — per-account MFA policy verdict; a stale `true` would
            // gate the next user against a requirement that is not theirs.
            "mfaEnrollmentGateStore",
            "moodHealthSyncStore",
            "moodStore", "moodTagCatalogStore", "moodTagManagementStore",
            "nightscoutIntegrationStore", // v1.18.7 web-parity — clearOnLogout in cascade
            "nutrientStore", // Build 7.6 (#48) — clearOnLogout (nutrient read cache)
            "environmentStore", // Build 7.7 — clearOnLogout (environment read cache)
            "stravaIntegrationStore", // Build 7.10 (#46) — clearOnLogout (connector state)
            "onboardingTourStore", // #32 — clearOnLogout in cascade (next user reconciles own tour flag)
            "ouraIntegrationStore", // v1.18.7 web-parity — clearOnLogout in cascade
            "passkeyManagementStore",
            "polarIntegrationStore", // v1.18.7 web-parity — clearOnLogout in cascade
            // parity 2.2 — per-user security inventory; leaving it behind would
            // show the previous account's sessions to the next sign-in.
            "sessionsStore",
            "serverStatsStores", "settingsStore", "syncModeStore",
            "trendsOverlayStore",
            "wellnessCardVisibilityStore", // v0141 — clearOnLogout in cascade (UI-pref hidden-set)
            "whoopIntegrationStore",
            "withingsIntegrationStore"
        ]

        /// Stores that deliberately survive `performFullLocalLogout` — each
        /// with a reviewed reason. Keep this list SHORT.
        private static let intentionallyExempt: Set<String> = [
            // Drives the logout itself: wipes the auth bundle + flips the
            // phase in `AuthStore.logout()` / `handleUnauthorized()` before
            // the cascade fires. Resetting it from inside the cascade would
            // recurse into the hooks that invoked it.
            "authStore"
        ]

        /// Reflection sweep: every `AppContainer` property whose type is a
        /// store (`…Store` / `…Stores`) must appear in exactly one of the two
        /// lists above. A new store that skips the logout decision — the bug
        /// class behind mood (v0.10), workouts (v1.15), cycle (B175 H-1) and
        /// the M-1 sweep — fails here at PR time instead of at the next
        /// security audit.
        @Test("every store-typed AppContainer property is classified for logout")
        func registryClassifiesEveryStoreProperty() throws {
            let container = try makeContainer(
                keychain: InMemoryKeychain(),
                healthKit: MockHealthKitWriter()
            )
            let storeProperties = Self.storeTypedProperties(of: container)
            // Sanity: reflection actually found the container's stores — a
            // refactor that breaks the discovery must not pass vacuously.
            #expect(
                storeProperties.count >= 30,
                "Mirror sweep looks broken — found only \(storeProperties.count) store properties"
            )

            let classified = Self.resetOnLogout.union(Self.intentionallyExempt)
            for property in storeProperties.sorted() {
                #expect(
                    classified.contains(property),
                    """
                    AppContainer.\(property) is not classified for logout. Either wire it \
                    into performFullLocalLogout (clearOnLogout/deactivateOnLogout) and add \
                    it to `resetOnLogout`, or document why it survives logout in \
                    `intentionallyExempt`. (AUDIT-SECURITY-B175 M-1 — mood/workout/cycle \
                    all leaked through exactly this omission.)
                    """
                )
            }
            // Inverse: no stale registry entries for removed/renamed stores.
            let existing = Set(storeProperties)
            for name in classified.sorted() {
                #expect(
                    existing.contains(name),
                    "Registry entry `\(name)` no longer matches an AppContainer store property — remove or rename it."
                )
            }
            // No double classification.
            #expect(Self.resetOnLogout.isDisjoint(with: Self.intentionallyExempt))
        }

        // MARK: - AUD-7 H1: LogoutClearable registry is the cascade's source

        /// Store-typed `AppContainer` properties that are cleared by the
        /// **registry** iteration in `performFullLocalLogout` (the plain
        /// synchronous `clearOnLogout()` path — i.e. they conform to
        /// `LogoutClearable`). This is the AUD-7 H1 fix: a forgettable hand-list
        /// became a protocol-driven registry. Every name here MUST conform to
        /// `LogoutClearable` and appear in `container.logoutClearables`.
        private static let registryCleared: Set<String> = [
            // Build 3 — Custom Metrics: Katalog + Eintraege gehoeren dem Konto.
            "customMetricsStore",
            // Parity Phase 2 — account-scoped stores added with the security hub,
            // sessions list and forced-MFA gate. All three hold data that belongs
            // to the signed-in account and must not survive a logout.
            "accountSecurityStore",
            "sessionsStore",
            "mfaEnrollmentGateStore",
            "achievementsStore", "aiProviderStore", "allergiesStore",
            "familyHistoryStore", "avatarStore", "chartsStore",
            "coachCadenceSuggestionsStore", "coachNudgeStore", "cycleStore",
            "dailyBriefingStore", "dashboardLayoutStore", "dashboardStore",
            "deliveryPreferencesStore", "diabetesStore", "disclaimerAckStore",
            "doctorReportStore", "documentsStore", "featureFlagsStore",
            "fitbitIntegrationStore",
            "healthScoreStore", "hkReadinessStore", "illnessStore",
            "injectionSitePrefsStore", "insightsLayoutStore", "insightsStore",
            "labsStore", "liveHealthKitTodayStore", "localDoctorReportStore",
            "measurementsStore", "medicationsStore", "mentalHealthStore",
            "moodStore", "moodTagCatalogStore", "moodTagManagementStore",
            "nightscoutIntegrationStore", "nutrientStore", "environmentStore",
            "stravaIntegrationStore", "onboardingTourStore",
            "ouraIntegrationStore", "passkeyManagementStore",
            "polarIntegrationStore", "settingsStore",
            "syncModeStore", "trendsOverlayStore",
            "wellnessCardVisibilityStore", // v0141 — UI-pref hidden-set
            "whoopIntegrationStore",
            "withingsIntegrationStore"
        ]

        /// The `logoutClearables` Mirror registry must collect EXACTLY the
        /// `LogoutClearable`-conforming stored properties — no more, no less.
        /// This is the enforced invariant behind AUD-7 H1: a store dropping out
        /// of the registry (e.g. a conformance accidentally removed, or a new
        /// PHI store added without conforming) is caught here, not at the next
        /// security audit. The intersection with the store-typed sweep proves the
        /// registry-cleared set lines up with the reflection property names.
        @Test("logoutClearables registry == the conforming store set (AUD-7 H1)")
        func registryMatchesConformingStores() throws {
            let container = try makeContainer(
                keychain: InMemoryKeychain(),
                healthKit: MockHealthKitWriter()
            )

            // Sanity: the registry actually found the clearables.
            #expect(
                container.logoutClearables.count >= 30,
                "logoutClearables registry looks broken — found only \(container.logoutClearables.count)"
            )

            // Resolve each registry entry back to its `AppContainer` property
            // label so we can compare against the expected conforming set.
            let conformingLabels = Set(
                Mirror(reflecting: container).children.compactMap { child -> String? in
                    guard let label = child.label else { return nil }
                    return (child.value as? any LogoutClearable) != nil ? label : nil
                }
            )

            #expect(
                conformingLabels == Self.registryCleared,
                """
                LogoutClearable conformance set drifted from the expected registry. \
                Difference — missing: \(Self.registryCleared.subtracting(conformingLabels).sorted()); \
                unexpected: \(conformingLabels.subtracting(Self.registryCleared).sorted()). \
                A new PHI store MUST conform to LogoutClearable (so the cascade clears \
                it) AND be added to `registryCleared`. (AUD-7 H1.)
                """
            )

            // Every registry-cleared store is also classified reset-on-logout in
            // the broader sweep — the two lists must agree.
            #expect(Self.registryCleared.isSubset(of: Self.resetOnLogout))

            // The registry instance count matches the conforming-label count
            // (no duplicate / phantom entries).
            #expect(container.logoutClearables.count == conformingLabels.count)
        }

        /// End-to-end: a logout cascade run must leave every registry-cleared
        /// store in its pristine empty state. Seeds a representative PHI store
        /// (medications) that is cleared via the REGISTRY (not an explicit call),
        /// then proves the cascade emptied it — i.e. the registry iteration
        /// actually fires `clearOnLogout()`.
        @Test("registry-driven cascade clears a registry-only store (AUD-7 H1)")
        func registryCascadeClearsMedications() async throws {
            let container = try makeContainer(
                keychain: InMemoryKeychain(),
                healthKit: MockHealthKitWriter()
            )
            container.medicationsStore.medications = [
                Medication(
                    id: "m1", name: "Naproxen", dose: "400 mg",
                    schedule: MedicationSchedule(times: []), active: true
                )
            ]
            #expect(!container.medicationsStore.medications.isEmpty)

            await container.performFullLocalLogout(reason: .userInitiated)

            #expect(container.medicationsStore.medications.isEmpty)
        }

        // MARK: - M-1/M-2/M-3: the newly wired stores actually reset

        /// The previously dead `SyncModeStore.clearOnLogout()` is wired: the
        /// runtime mode (in-memory + `hl.syncMode` default) is dropped so the
        /// next launch re-enters the onboarding picker instead of silently
        /// re-pairing against the previous account's server.
        @Test("logout clears the persisted sync-mode (M-1)")
        func logoutClearsSyncMode() async throws {
            let container = try makeContainer(
                keychain: InMemoryKeychain(),
                healthKit: MockHealthKitWriter()
            )
            defer { UserDefaults.standard.removeObject(forKey: SyncModeStore.storageKey) }
            container.syncModeStore.setMode(.paired)
            #expect(container.syncModeStore.mode == .paired)

            await container.performFullLocalLogout(reason: .userInitiated)

            #expect(container.syncModeStore.mode == nil)
            #expect(UserDefaults.standard.string(forKey: SyncModeStore.storageKey) == nil)
        }

        /// An un-saved typed API key in the AI-provider draft must never
        /// survive into the next user's session; the chart configuration
        /// (range / metric selection) is per-user taste and resets too.
        @Test("logout clears AI-provider drafts + trends configuration (M-1)")
        func logoutClearsDraftsAndTrendsConfig() async throws {
            let container = try makeContainer(
                keychain: InMemoryKeychain(),
                healthKit: MockHealthKitWriter()
            )
            container.aiProviderStore.draftAPIKey = "sk-test-NEVER-LEAK"
            container.aiProviderStore.draftModel = "provider-model-x"
            container.trendsOverlayStore.range = .year
            container.trendsOverlayStore.selectedMetrics = [.glucose]
            container.trendsOverlayStore.averaging = .monthly

            await container.performFullLocalLogout(reason: .userInitiated)

            #expect(container.aiProviderStore.draftAPIKey.isEmpty)
            #expect(container.aiProviderStore.draftModel.isEmpty)
            #expect(container.aiProviderStore.config == nil)
            #expect(container.trendsOverlayStore.range == .month)
            #expect(container.trendsOverlayStore.selectedMetrics == TrendsOverlayStore.defaultSelection)
            #expect(container.trendsOverlayStore.averaging == .none)
            #expect(container.trendsOverlayStore.normalisedSeries.isEmpty)
        }

        /// The previously dead `HKReadinessStore.clearOnLogout()` is wired:
        /// the next user must not see the previous user's last-synced time.
        @Test("logout clears the HK-readiness snapshot (M-1)")
        func logoutClearsHKReadiness() async throws {
            let container = try makeContainer(
                keychain: InMemoryKeychain(),
                healthKit: MockHealthKitWriter()
            )
            defer {
                UserDefaults.standard.removeObject(forKey: HKReadinessStore.lastSyncedKey(for: nil))
            }
            container.hkReadinessStore.noteSuccessfulSync(at: .now)
            #expect(container.hkReadinessStore.lastSyncedAt != nil)

            await container.performFullLocalLogout(reason: .userInitiated)

            #expect(container.hkReadinessStore.lastSyncedAt == nil)
        }

        /// M-3 — the per-medication delivery overrides (`hl.delivery.*`, incl.
        /// scope markers and the legacy `hl.liveActivity.enabled.*` keys)
        /// reveal *that* medication entities existed and are previous-user-
        /// scoped garbage for the next account. The logout sweep removes them.
        @Test("logout wipes the hl.delivery.* / legacy live-activity defaults (M-3)")
        func logoutWipesDeliveryPreferenceDefaults() async throws {
            let defaults = UserDefaults.standard
            let valueKey = "hl.delivery.liveActivity.med-prev-user"
            let scopeKey = "hl.delivery.scope.liveActivity.med-prev-user"
            let legacyKey = "hl.liveActivity.enabled.med-prev-user"
            defer {
                defaults.removeObject(forKey: valueKey)
                defaults.removeObject(forKey: scopeKey)
                defaults.removeObject(forKey: legacyKey)
            }
            let container = try makeContainer(
                keychain: InMemoryKeychain(),
                healthKit: MockHealthKitWriter()
            )
            defaults.set(true, forKey: valueKey)
            defaults.set("thisDevice", forKey: scopeKey)
            defaults.set(false, forKey: legacyKey)

            await container.performFullLocalLogout(reason: .userInitiated)

            #expect(defaults.object(forKey: valueKey) == nil)
            #expect(defaults.object(forKey: scopeKey) == nil)
            #expect(defaults.object(forKey: legacyKey) == nil)
        }

        /// M-1 — the four `ServerStatsStores` members the hand-maintained
        /// per-member call list had silently missed are covered now that the
        /// cascade calls the canonical bundle helper. Narrative is the
        /// seedable proxy: its inputs hash survives `clearOnLogout()` only if
        /// the bundle call were dropped again.
        @Test("logout resets ALL ServerStatsStores members via the bundle helper (M-1)")
        func logoutResetsServerStatsBundle() async throws {
            let container = try makeContainer(
                keychain: InMemoryKeychain(),
                healthKit: MockHealthKitWriter()
            )
            // moodRelations + narrative were two of the four missed members.
            // Both expose only repo-driven loads, so the observable signal we
            // can pin without a network is that the cascade leaves them in
            // their pristine post-init state (no data / no per-period rows).
            let moodRelations = container.serverStatsStores.moodRelations
            let narrative = container.serverStatsStores.narrative

            await container.performFullLocalLogout(reason: .userInitiated)

            #expect(moodRelations.response == nil)
            #expect(narrative.byPeriod.isEmpty)
        }

        // MARK: - v1.18.6 PHI — labs + illness store purge

        /// Lab results + the biomarker catalog are clinical PHI; the promoted
        /// container store must drop them on logout so the next user never
        /// inherits the predecessor's labs.
        @Test("logout purges the labs store (v1.18.6 PHI)")
        func logoutPurgesLabsStore() async throws {
            let container = try makeContainer(
                keychain: InMemoryKeychain(),
                healthKit: MockHealthKitWriter()
            )
            container.labsStore.seedForTesting(
                labs: [
                    LabResultDTO(
                        id: "l1", biomarkerId: nil, panel: nil, analyte: "HbA1c",
                        value: 5.4, unit: "%", referenceLow: nil, referenceHigh: nil,
                        takenAt: "2026-01-01T00:00:00Z", source: "MANUAL", hasNote: false,
                        rangeStatus: .inRange, createdAt: "", updatedAt: ""
                    )
                ],
                biomarkers: [
                    BiomarkerDTO(
                        id: "b1", name: "HbA1c", unit: "%", lowerBound: nil, upperBound: nil,
                        panel: nil, hasContext: false, context: nil, createdAt: "", updatedAt: ""
                    )
                ]
            )
            #expect(!container.labsStore.labs.isEmpty)

            await container.performFullLocalLogout(reason: .userInitiated)

            #expect(container.labsStore.labs.isEmpty)
            #expect(container.labsStore.biomarkers.isEmpty)
            #expect(container.labsStore.total == 0)
        }

        /// Illness episodes + day-logs (symptoms, fever, functional impact) are
        /// clinical PHI; the promoted container store must purge them on logout.
        @Test("logout purges the illness store (v1.18.6 PHI)")
        func logoutPurgesIllnessStore() async throws {
            let container = try makeContainer(
                keychain: InMemoryKeychain(),
                healthKit: MockHealthKitWriter()
            )
            let episode = IllnessEpisodeDTO(
                id: "ep1", label: "Flu", type: .infection, lifecycle: .acute,
                onsetAt: "2026-01-01T00:00:00Z", resolvedAt: nil, parentConditionId: nil,
                note: nil, createdAt: "", updatedAt: ""
            )
            container.illnessStore.seedForTesting(episodes: [episode], selected: episode)
            #expect(!container.illnessStore.episodes.isEmpty)

            await container.performFullLocalLogout(reason: .userInitiated)

            #expect(container.illnessStore.episodes.isEmpty)
            #expect(container.illnessStore.selectedEpisode == nil)
            #expect(container.illnessStore.dayLogsByDate.isEmpty)
        }

        // MARK: - v1.25 PHI — allergy + family-history store purge

        /// Allergies carry decrypted `reaction` + `note` PHI; the container store
        /// must drop them on logout so the next user never inherits the
        /// predecessor's allergies.
        @Test("logout purges the allergies store (v1.25 PHI)")
        func logoutPurgesAllergiesStore() async throws {
            let container = try makeContainer(
                keychain: InMemoryKeychain(),
                healthKit: MockHealthKitWriter()
            )
            container.allergiesStore.seedForTesting(records: [
                AllergyDTO(
                    id: "a1", substance: "Penicillin", category: .medication, type: .allergy,
                    severity: .severe, status: .active, onsetAt: nil,
                    reaction: "Anaphylaxis", note: "epi-pen", createdAt: "", updatedAt: ""
                )
            ])
            #expect(!container.allergiesStore.records.isEmpty)

            await container.performFullLocalLogout(reason: .userInitiated)

            #expect(container.allergiesStore.records.isEmpty)
        }

        /// Family-history entries carry a decrypted `note` PHI; the container store
        /// must purge them on logout.
        @Test("logout purges the family-history store (v1.25 PHI)")
        func logoutPurgesFamilyHistoryStore() async throws {
            let container = try makeContainer(
                keychain: InMemoryKeychain(),
                healthKit: MockHealthKitWriter()
            )
            container.familyHistoryStore.seedForTesting(records: [
                FamilyHistoryEntryDTO(
                    id: "f1", relationship: .mother, condition: "Breast cancer",
                    ageAtOnset: 52, note: "BRCA1", createdAt: "", updatedAt: ""
                )
            ])
            #expect(!container.familyHistoryStore.records.isEmpty)

            await container.performFullLocalLogout(reason: .userInitiated)

            #expect(container.familyHistoryStore.records.isEmpty)
        }

        /// The mental-health screener history (instrument / band / date) + any
        /// in-flight (PHI) item answers must drop on logout so the next user never
        /// inherits the predecessor's PHQ-9 / GAD-7 data.
        @Test("logout purges the mental-health store (v1.25 PHI)")
        func logoutPurgesMentalHealthStore() async throws {
            let container = try makeContainer(
                keychain: InMemoryKeychain(),
                healthKit: MockHealthKitWriter()
            )
            container.mentalHealthStore.seedForTesting(history: [
                MentalHealthAssessmentDTO(
                    id: "mh1", instrument: .phq9, locale: "en", version: "standard",
                    totalScore: 18, severityBand: "modSevere", item9Flagged: true,
                    crisisShownAt: "2026-06-28T00:00:00Z", takenAt: "2026-06-28T00:00:00Z",
                    createdAt: "2026-06-28T00:00:00Z"
                )
            ])
            #expect(!container.mentalHealthStore.history.isEmpty)

            await container.performFullLocalLogout(reason: .userInitiated)

            #expect(container.mentalHealthStore.history.isEmpty)
            #expect(container.mentalHealthStore.result == nil)
        }

        // MARK: - v0150 sec-L1 — dedicated purge tests for the three Mirror-only stores

        /// The diabetes opt-in is a personal-health attribute (it changes the
        /// server-side glucose status bands). It rides the Mirror-classification
        /// test for logout coverage; this is the dedicated seed→logout→empty proof
        /// (belt-and-suspenders).
        @Test("logout purges the diabetes store (v0150 sec-L1)")
        func logoutPurgesDiabetesStore() async throws {
            let container = try makeContainer(
                keychain: InMemoryKeychain(),
                healthKit: MockHealthKitWriter()
            )
            container.diabetesStore.seedForTesting(hasDiabetes: true)
            #expect(container.diabetesStore.hasDiabetes == true)

            await container.performFullLocalLogout(reason: .userInitiated)

            #expect(container.diabetesStore.hasDiabetes == nil)
        }

        /// Preventive-care reminders (label / location / next-due) are per-user
        /// data; the promoted container store must drop them on logout so the next
        /// user never inherits the predecessor's reminders.
        @Test("logout purges the measurement-reminders store (v0150 sec-L1)")
        func logoutPurgesMeasurementRemindersStore() async throws {
            let container = try makeContainer(
                keychain: InMemoryKeychain(),
                healthKit: MockHealthKitWriter()
            )
            container.measurementRemindersStore.reminders = [
                MeasurementReminderRow(
                    id: "r1", label: "Blutdruck", measurementType: "blood_pressure",
                    intervalDays: 30, rrule: nil, endsOn: nil, origin: .vorsorge,
                    notifyHour: 9, location: nil, nextDueAt: Date(),
                    lastSatisfiedAt: nil, enabled: true
                )
            ]
            #expect(!container.measurementRemindersStore.reminders.isEmpty)

            await container.performFullLocalLogout(reason: .userInitiated)

            #expect(container.measurementRemindersStore.reminders.isEmpty)
        }

        /// The Coach unread nudge signal is per-user; a stale unread must never
        /// bleed across accounts. The dot rides the Mirror test for coverage; this
        /// proves the seed→logout→cleared cascade directly.
        @Test("logout purges the coach-nudge store (v0150 sec-L1)")
        func logoutPurgesCoachNudgeStore() async throws {
            let container = try makeContainer(
                keychain: InMemoryKeychain(),
                healthKit: MockHealthKitWriter()
            )
            container.coachNudgeStore.seedForTesting(unread: true, nudgedAt: Date())
            #expect(container.coachNudgeStore.unread)
            #expect(container.coachNudgeStore.nudgedAt != nil)

            await container.performFullLocalLogout(reason: .userInitiated)

            #expect(!container.coachNudgeStore.unread)
            #expect(container.coachNudgeStore.nudgedAt == nil)
        }

        // MARK: - W-B187 (AUDIT-SEC-b187) — Mini-Coach box wipe

        /// **B1 (Blocker)** — the Coach "About me" self-context is per-user PHI
        /// (medical conditions / allergies / coach-focus). `MiniCoachBox` is the
        /// ONE per-user store cache the cascade skipped, and `coachAboutMeStore`
        /// is a *computed* (box-backed) property invisible to the reflection
        /// registry above — so this leak needs an explicit behavioural test.
        ///
        /// Proves both halves: (a) the cached instance a retained SwiftUI
        /// snapshot might still hold has its PHI wiped + `didLoad` reset, and
        /// (b) re-resolving `coachAboutMeStore` returns a fresh, empty store so
        /// the next user's About-Me editor reloads against their own partition
        /// instead of rendering the predecessor's drafts.
        @Test("logout wipes the cached Coach About-Me PHI + drops the cache (B1)")
        func logoutWipesCoachAboutMe() async throws {
            let container = try makeContainer(
                keychain: InMemoryKeychain(),
                healthKit: MockHealthKitWriter()
            )
            // Resolve + seed the box-cached store as if User A had loaded it.
            let cachedAboutMe = container.coachAboutMeStore
            cachedAboutMe.seedLoadedStateForTesting(
                aboutMe: "I run marathons",
                conditions: "Hypertension",
                allergies: "Penicillin",
                coachFocus: "Lower my blood pressure",
                pendingQuestions: ["What is your target BP?"]
            )
            #expect(cachedAboutMe.didLoad)
            #expect(cachedAboutMe.conditions == "Hypertension")

            await container.performFullLocalLogout(reason: .userInitiated)

            // (a) the previously cached instance is wiped in place.
            #expect(cachedAboutMe.aboutMe.isEmpty)
            #expect(cachedAboutMe.conditions.isEmpty)
            #expect(cachedAboutMe.allergies.isEmpty)
            #expect(cachedAboutMe.coachFocus.isEmpty)
            #expect(cachedAboutMe.pendingQuestions.isEmpty)
            #expect(cachedAboutMe.didLoad == false)

            // (b) re-resolving returns a fresh instance (cache dropped) that the
            // SettingsAboutMeScreen `if !s.didLoad` guard will reload.
            let fresh = container.coachAboutMeStore
            #expect(fresh !== cachedAboutMe)
            #expect(fresh.didLoad == false)
            #expect(fresh.conditions.isEmpty)
        }

        /// **High** — the in-session coach conversation lives in the same
        /// un-cleared `MiniCoachBox`. Without the wipe, User B inherits User A's
        /// leftover chat. Proves the cached store's `messages` are emptied and
        /// the cache is dropped so a re-resolution starts blank.
        @Test("logout wipes the in-session Mini-Coach conversation (High)")
        func logoutWipesMiniCoachConversation() async throws {
            let container = try makeContainer(
                keychain: InMemoryKeychain(),
                healthKit: MockHealthKitWriter()
            )
            let cachedStore = container.miniCoachStore
            cachedStore.seedMessagesForTesting([
                .init(role: .user, text: "Is 200 mg naproxen ok for me?"),
                .init(role: .assistant, text: "Here is some general info…")
            ])
            #expect(cachedStore.messages.isEmpty == false)

            await container.performFullLocalLogout(reason: .userInitiated)

            // (a) the previously cached conversation is emptied in place.
            #expect(cachedStore.messages.isEmpty)
            #expect(cachedStore.isThinking == false)

            // (b) re-resolving returns a fresh store with no leftover turns.
            let fresh = container.miniCoachStore
            #expect(fresh !== cachedStore)
            #expect(fresh.messages.isEmpty)
        }

        // MARK: - Helpers

        func makeContainer(
            keychain: InMemoryKeychain,
            healthKit: AnyHealthKitWriter?
        ) throws -> AppContainer {
            try AppContainer(
                environment: testEnvironment(),
                keychain: keychain,
                passkey: TestPasskeyService(),
                healthKit: healthKit
            )
        }

        func testEnvironment() throws -> AppEnvironment {
            AppEnvironment(
                baseURL: URL(string: "https://example.invalid"),
                bundleID: "dev.healthlog.app.tests",
                appVersion: "0.0.0-test",
                buildNumber: "0"
            )
        }

        /// All store-typed property labels of `AppContainer` (type name ends
        /// in `Store`/`Stores`, optionals unwrapped). Internal (not `private`)
        /// so the box-backed-coverage sibling file (W-PHI-HARDENING G5) can
        /// assert the box stores are absent from this stored-property sweep.
        static func storeTypedProperties(of container: AppContainer) -> [String] {
            Mirror(reflecting: container).children.compactMap { child in
                guard let label = child.label else { return nil }
                var typeName = String(describing: type(of: child.value))
                if typeName.hasPrefix("Optional<"), typeName.hasSuffix(">") {
                    typeName = String(typeName.dropFirst("Optional<".count).dropLast())
                }
                guard typeName.hasSuffix("Store") || typeName.hasSuffix("Stores") else { return nil }
                return label
            }
        }
    }

    // MARK: - Plan 06-05 — exact explicit-registry canary (test-only reflection)

    @MainActor
    extension LogoutCompletenessTests {
        /// Absolute repository root derived from this file's compile-time path.
        /// Lets the suite read production sources AS DATA for the
        /// no-production-reflection assertion (simulator tests share the host
        /// filesystem, so the read is deterministic on the build machine).
        static var repositoryRoot: URL {
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent() // Stores
                .deletingLastPathComponent() // HealthLogTests
                .deletingLastPathComponent() // repository root
        }

        /// `relativePath` source lines that invoke runtime reflection
        /// (`Mirror(reflecting:`). Empty means the production file composes its
        /// cleanup membership explicitly. An unreadable file returns a sentinel
        /// hit so missing evidence fails closed instead of passing vacuously.
        static func productionReflectionHits(relativePath: String) -> [String] {
            let url = repositoryRoot.appendingPathComponent(relativePath)
            guard let source = try? String(contentsOf: url, encoding: .utf8) else {
                return ["<unreadable: \(relativePath)>"]
            }
            return source
                .split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated()
                .filter { $0.element.contains("Mirror(reflecting:") }
                .map { "\(relativePath):\($0.offset + 1)" }
        }

        /// **06-05 Task 1 — the exact-identity completeness canary.** The
        /// production `logoutClearables` registry must be an EXPLICIT typed
        /// composition that covers every `LogoutClearable`-conforming stored
        /// `AppContainer` property exactly once — discovered here by the
        /// test-side reflection sweep, which stays the independent canary. A
        /// missing, duplicate, or unknown member fails with its property label
        /// (non-PHI), and any `Mirror(reflecting:` use in the production
        /// registry file fails the same behavioral invariant.
        @Test
        func productionRegistryIsExplicitAndExactlyComplete() throws {
            let container = try makeContainer(
                keychain: InMemoryKeychain(),
                healthKit: MockHealthKitWriter()
            )

            // Independent test-side canary: label + identity of every
            // conforming stored property.
            var reflectedLabelByID: [ObjectIdentifier: String] = [:]
            for child in Mirror(reflecting: container).children {
                guard let label = child.label,
                      let clearable = child.value as? any LogoutClearable else { continue }
                reflectedLabelByID[ObjectIdentifier(clearable)] = label
            }
            #expect(
                reflectedLabelByID.count >= 30,
                "test-side reflection canary looks broken — found only \(reflectedLabelByID.count) conformers"
            )

            let registryIDs = container.logoutClearables.map { ObjectIdentifier($0) }
            let registryIDSet = Set(registryIDs)

            // Missing: a conforming store the production registry does not clear.
            let missingLabels = reflectedLabelByID
                .filter { !registryIDSet.contains($0.key) }
                .map(\.value)
                .sorted()
            // Duplicates: an owner listed more than once would double-clear.
            let duplicateCount = registryIDs.count - registryIDSet.count
            // Unknown: a registry member that is not a conforming stored property.
            let unknownCount = registryIDSet.subtracting(reflectedLabelByID.keys).count
            let reflectionHits = Self.productionReflectionHits(
                relativePath: "HealthLog/Stores/AppContainer+Logout.swift"
            )

            #expect(
                missingLabels.isEmpty && duplicateCount == 0 && unknownCount == 0
                    && reflectionHits.isEmpty,
                "EXPECTED_RED: production registry membership was not exact — missing \(missingLabels), duplicates \(duplicateCount), unknown \(unknownCount), production reflection \(reflectionHits)"
            )
        }
    }

    // MARK: - DISC-02 — disclaimer-ack store purge

    @MainActor
    extension LogoutCompletenessTests {
        /// The one-time medical-disclaimer acknowledgment is a local mirror of
        /// the server `disclaimerAcknowledgedAt`. It must drop on logout so a
        /// different user signing in on the same device re-sees the one-time
        /// disclaimer until THEY acknowledge (it is re-fetched from `/me` on the
        /// next login). The store rides the Mirror-classification test for
        /// logout coverage; this is the dedicated seed→logout→empty proof.
        @Test("logout purges the disclaimer-ack store (DISC-02)")
        func logoutPurgesDisclaimerAckStore() async throws {
            let container = try makeContainer(
                keychain: InMemoryKeychain(),
                healthKit: MockHealthKitWriter()
            )
            container.disclaimerAckStore.seedForTesting(isAcknowledged: true, hasLoaded: true)
            #expect(container.disclaimerAckStore.isAcknowledged)
            #expect(container.disclaimerAckStore.hasLoaded)

            await container.performFullLocalLogout(reason: .userInitiated)

            #expect(container.disclaimerAckStore.isAcknowledged == false)
            #expect(container.disclaimerAckStore.hasLoaded == false)
        }

        /// **Build 9 (Server-Prefs) / 9.1** — the server-owned `unitPreference`
        /// mirror + its one-time migration flag are per-user. Seeded before the
        /// container is built (so the store inits from them), they must be gone +
        /// the property back on `.metric` after logout so the next user
        /// migrates/hydrates fresh. (Behavioural assert — no new AppContainer
        /// store, the registry sets are unchanged: `settingsStore` is already
        /// classified reset-on-logout.)
        @Test("logout clears the unit-preference mirror + migration flag (Build 9)")
        func logoutClearsUnitPreferenceMirror() async throws {
            let defaults = UserDefaults.standard
            let mirrorKey = HLUnitPreference.defaultsKey
            let flagKey = "hl.settings.unitPref.migrated.v1"
            defer {
                defaults.removeObject(forKey: mirrorKey)
                defaults.removeObject(forKey: flagKey)
            }
            defaults.set(HLUnitPreference.imperial.rawValue, forKey: mirrorKey)
            defaults.set(true, forKey: flagKey)

            let container = try makeContainer(
                keychain: InMemoryKeychain(),
                healthKit: MockHealthKitWriter()
            )
            #expect(container.settingsStore.unitPreference == .imperial)

            await container.performFullLocalLogout(reason: .userInitiated)

            #expect(container.settingsStore.unitPreference == .metric)
            #expect(defaults.object(forKey: mirrorKey) == nil)
            #expect(defaults.object(forKey: flagKey) == nil)
        }

        /// **Build 9 (Server-Prefs) / 9.2** — the two coach mirror keys
        /// (`hl.settings.coach.disabled` + the reminder-suggestions mirror) are
        /// per-user. The box-cached `aiCoachSettingsStore` is wiped by the cascade
        /// (`AICoachSettingsBox.clearStore`), which must remove both keys so the
        /// next user hydrates fresh. (Behavioural assert — the box is invisible to
        /// the reflection registry, like the Mini-Coach box.)
        @Test("logout clears the coach disable + reminder mirror keys (Build 9)")
        func logoutClearsCoachMirrors() async throws {
            let defaults = UserDefaults.standard
            let coachKey = "hl.settings.coach.disabled"
            let reminderKey = CoachCadenceSuggestionsDefaultsKeys.serverMirrorEnabled
            defer {
                defaults.removeObject(forKey: coachKey)
                defaults.removeObject(forKey: reminderKey)
            }
            defaults.set(true, forKey: coachKey)
            defaults.set(false, forKey: reminderKey)

            let container = try makeContainer(
                keychain: InMemoryKeychain(),
                healthKit: MockHealthKitWriter()
            )
            // Resolve the box-cached store so the cascade has an instance to clear.
            _ = container.aiCoachSettingsStore

            await container.performFullLocalLogout(reason: .userInitiated)

            #expect(container.aiCoachSettingsStore.coachDisabled == nil)
            #expect(container.aiCoachSettingsStore.reminderSuggestionsEnabled == nil)
            #expect(defaults.object(forKey: coachKey) == nil)
            #expect(defaults.object(forKey: reminderKey) == nil)
        }

        /// **Build 9 (Server-Prefs) / 9.3** — the cycle opt-in cache + its server
        /// mirror + migration flag are per-user. Seeded before the container is
        /// built, they must be gone + the opt-in back to `false` after logout
        /// (also closing the pre-existing gap where the opt-in survived logout).
        @Test("logout clears the cycle opt-in + server mirror + migration flag (Build 9)")
        func logoutClearsCyclePrefs() async throws {
            let defaults = UserDefaults.standard
            let optInKey = "hl.settings.cycleTracking.optIn"
            let serverKey = "hl.settings.cycleTracking.serverEnabled"
            let flagKey = "hl.settings.cycleTracking.migrated.v1"
            defer {
                defaults.removeObject(forKey: optInKey)
                defaults.removeObject(forKey: serverKey)
                defaults.removeObject(forKey: flagKey)
            }
            defaults.set(true, forKey: optInKey)
            defaults.set(true, forKey: serverKey)
            defaults.set(true, forKey: flagKey)

            let container = try makeContainer(
                keychain: InMemoryKeychain(),
                healthKit: MockHealthKitWriter()
            )
            #expect(container.settingsStore.cycleTrackingOptIn == true)

            await container.performFullLocalLogout(reason: .userInitiated)

            #expect(container.settingsStore.cycleTrackingOptIn == false)
            #expect(defaults.object(forKey: optInKey) == nil)
            #expect(defaults.object(forKey: serverKey) == nil)
            #expect(defaults.object(forKey: flagKey) == nil)
        }
    }

#endif // !SWIFT_PACKAGE
