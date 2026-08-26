// Diese Suite testet App-Target-Symbole (`HKReadinessStore`,
// `SettingsHealthAccessScreen`), die in der SPM-Library nicht enthalten sind.
// SPM-Test-Build überspringt die Datei.
#if !SWIFT_PACKAGE

    import Foundation
    #if canImport(HealthKit)
        import HealthKit
    #endif
    @testable import HealthLog
    import Testing

    #if canImport(HealthKit)

        // MARK: - Test-Double

        /// `HealthKitServiceProtocol`-Double mit **veränderlichen** Schreib-Status.
        /// `requestAuthorization` wendet optional eine Mutation an — damit lässt
        /// sich der Unterschied zwischen „iOS hat den Sheet still geschlossen“
        /// und „der Nutzer hat wirklich etwas erteilt“ nachstellen, ohne einen
        /// echten `HKHealthStore`.
        final class MutableWriteStatusService: HealthKitServiceProtocol, @unchecked Sendable {
            private let lock = NSLock()
            private var statuses: [String: HKReadinessStore.AuthStatus]
            private let onRequest: (@Sendable ([String: HKReadinessStore.AuthStatus])
                -> [String: HKReadinessStore.AuthStatus])?
            private var _requestCount = 0

            /// Die Identifier der drei Schreibtypen, für die das Double Status
            /// liefert (`HKQuantityType` selbst ist nicht `Sendable`, taugt also
            /// nicht als statische Konstante).
            static let bodyMassID = HKQuantityTypeIdentifier.bodyMass.rawValue
            static let bloodGlucoseID = HKQuantityTypeIdentifier.bloodGlucose.rawValue
            static let oxygenSaturationID = HKQuantityTypeIdentifier.oxygenSaturation.rawValue

            init(
                statuses: [String: HKReadinessStore.AuthStatus],
                onRequest: (@Sendable ([String: HKReadinessStore.AuthStatus])
                    -> [String: HKReadinessStore.AuthStatus])? = nil
            ) {
                self.statuses = statuses
                self.onRequest = onRequest
            }

            var requestCount: Int {
                lock.withLock { _requestCount }
            }

            // MARK: Capability + status

            func isAvailable() -> Bool {
                true
            }

            func authorizationStatus(for _: HKObjectType) -> HKAuthorizationStatus {
                .notDetermined
            }

            func authorizationStatuses(for types: Set<HKSampleType>) -> [String: HKReadinessStore.AuthStatus] {
                lock.withLock {
                    var result: [String: HKReadinessStore.AuthStatus] = [:]
                    for type in types {
                        result[type.identifier] = statuses[type.identifier] ?? .notDetermined
                    }
                    return result
                }
            }

            // MARK: Authorization

            func requestAuthorization(read _: Set<HKObjectType>, write _: Set<HKSampleType>) async throws {
                lock.withLock {
                    _requestCount += 1
                    if let onRequest { statuses = onRequest(statuses) }
                }
            }

            func resetAuthDisabledTypes() async {}

            func defaultReadTypes() -> Set<HKObjectType> {
                [HKQuantityType(.bodyMass), HKQuantityType(.bloodGlucose), HKQuantityType(.oxygenSaturation)]
            }

            func defaultWriteTypes() -> Set<HKSampleType> {
                [HKQuantityType(.bodyMass), HKQuantityType(.bloodGlucose), HKQuantityType(.oxygenSaturation)]
            }

            // MARK: Direct write + observation

            func writeMeasurement(_: HealthLog.Measurement) async throws {}
            func writeMoodEntry(_: MoodEntry) async throws {}
            func startBackgroundDeliveries() async throws {}

            // MARK: AnyHealthKitWriter required slice

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

        // MARK: - No-Op-Erkennung

        /// **H1 — warum der Hinweis beim Betreiber ausblieb.**
        ///
        /// Der Betreiber tippt „Mit Apple Health verbinden“, das System-Blatt
        /// blitzt auf und schließt sich sofort wieder. Die App erkennt das über
        /// `lastAuthorizationWasNoOp` und blendet dann den erklärenden Satz ein.
        /// Die Erkennung verglich bis H1 den **abgeleiteten** `state` vor und
        /// nach dem Blatt — und der faltet die `requestedAt`-Buchführung mit
        /// ein, die `markAuthorizationRequested()` mitten in derselben Methode
        /// umlegt. Aus `.unknown` bzw. `.notRequested` heraus sah deshalb jeder
        /// Aufruf nach Fortschritt aus (`.unknown` → `.partiallyGranted`),
        /// obwohl HealthKit keinen einzigen Status bewegt hatte.
        ///
        /// Seit H1 vergleicht die Erkennung die echten HealthKit-Schreibstatus.
        @MainActor
        @Suite("HKReadinessStore — No-Op-Erkennung am HealthKit-Status (H1)")
        struct HKReadinessNoOpDetectionTests {
            private static func makeDefaults() -> UserDefaults {
                // swiftlint:disable:next force_unwrapping
                UserDefaults(suiteName: "hl.tests.\(UUID().uuidString)")!
            }

            private static func makeStore(
                service: MutableWriteStatusService,
                userID: String
            ) throws -> HKReadinessStore {
                let keychain = InMemoryKeychain()
                try keychain.setString(userID, forKey: KeychainKey.userID)
                return HKReadinessStore(
                    healthKit: service,
                    backgroundSync: StubBackgroundSyncCoordinator(),
                    keychain: keychain,
                    defaults: makeDefaults()
                )
            }

            @Test("Regression: kein Status bewegt sich → No-Op, auch aus .unknown heraus")
            func noOpDetectedFromUnknownPreState() async throws {
                // Jeder fehlende Schreibtyp ist bereits abgelehnt; iOS fragt nie
                // ein zweites Mal danach → das Blatt blitzt auf und schließt sich.
                let service = MutableWriteStatusService(statuses: [
                    MutableWriteStatusService.bodyMassID: .sharingAuthorized,
                    MutableWriteStatusService.bloodGlucoseID: .sharingDenied,
                    MutableWriteStatusService.oxygenSaturationID: .sharingDenied
                ])
                let store = try Self.makeStore(service: service, userID: "noop-unknown")

                // Der Vorzustand ist `.unknown` — genau die Lage, in der die
                // alte Erkennung schwieg (kein `refresh()` vor dem Tippen).
                #expect(store.state == .unknown)
                await store.requestAuthorization()

                #expect(service.requestCount == 1)
                #expect(store.state == .partiallyGranted(missing: [
                    MutableWriteStatusService.bloodGlucoseID,
                    MutableWriteStatusService.oxygenSaturationID
                ].sorted()))
                #expect(
                    store.lastAuthorizationWasNoOp,
                    "Der Zustandssprung .unknown → .partiallyGranted ist reine Buchführung, kein Fortschritt."
                )
            }

            @Test("Eingeschwungen: .partiallyGranted bleibt .partiallyGranted → No-Op")
            func noOpDetectedFromSteadyState() async throws {
                let service = MutableWriteStatusService(statuses: [
                    MutableWriteStatusService.bodyMassID: .sharingAuthorized,
                    MutableWriteStatusService.bloodGlucoseID: .sharingDenied,
                    MutableWriteStatusService.oxygenSaturationID: .sharingDenied
                ])
                let store = try Self.makeStore(service: service, userID: "noop-steady")
                await store.refresh()
                guard case .partiallyGranted = store.state else {
                    Issue.record("Vorbedingung: erwartet .partiallyGranted, war \(store.state)")
                    return
                }

                await store.requestAuthorization()
                #expect(store.lastAuthorizationWasNoOp)
            }

            @Test("Echter Fortschritt: ein Typ wird erteilt → kein No-Op")
            func genuineProgressIsNotFlagged() async throws {
                let service = MutableWriteStatusService(
                    statuses: [
                        MutableWriteStatusService.bodyMassID: .sharingAuthorized,
                        MutableWriteStatusService.bloodGlucoseID: .notDetermined,
                        MutableWriteStatusService.oxygenSaturationID: .sharingDenied
                    ],
                    onRequest: { current in
                        var next = current
                        next[MutableWriteStatusService.bloodGlucoseID] = .sharingAuthorized
                        return next
                    }
                )
                let store = try Self.makeStore(service: service, userID: "noop-progress")
                await store.requestAuthorization()

                #expect(!store.lastAuthorizationWasNoOp)
            }

            @Test("Alles erteilt → kein No-Op, obwohl sich nichts mehr bewegen kann")
            func fullyGrantedIsNotFlagged() async throws {
                let service = MutableWriteStatusService(statuses: [
                    MutableWriteStatusService.bodyMassID: .sharingAuthorized,
                    MutableWriteStatusService.bloodGlucoseID: .sharingAuthorized,
                    MutableWriteStatusService.oxygenSaturationID: .sharingAuthorized
                ])
                let store = try Self.makeStore(service: service, userID: "noop-full")
                await store.requestAuthorization()

                #expect(store.state == .fullyGranted)
                #expect(!store.lastAuthorizationWasNoOp)
            }

            @Test("refresh() legt die Schreibstatus offen; clearOnLogout wischt sie")
            func writeStatusesAreExposedAndCleared() async throws {
                let service = MutableWriteStatusService(statuses: [
                    MutableWriteStatusService.bodyMassID: .sharingAuthorized,
                    MutableWriteStatusService.bloodGlucoseID: .sharingDenied,
                    MutableWriteStatusService.oxygenSaturationID: .notDetermined
                ])
                let store = try Self.makeStore(service: service, userID: "statuses")
                #expect(store.writeAuthorizationStatuses.isEmpty)

                await store.refresh()
                #expect(store.writeAuthorizationStatuses.count == 3)
                #expect(
                    store.writeAuthorizationStatuses[MutableWriteStatusService.bloodGlucoseID]
                        == .sharingDenied
                )

                store.clearOnLogout()
                #expect(store.writeAuthorizationStatuses.isEmpty)
            }
        }

        // MARK: - Farbe: was welcher Zustand sagen soll

        /// **H1 — Rot nur, wo der Nutzer handeln muss.**
        ///
        /// Vorher leitete jede Fläche ihren Pill-Fall selbst aus `state` ab:
        /// `SettingsIntegrationsScreen` malte `.partiallyGranted` unbesehen rot,
        /// `AppleHealthIntegrationDetailScreen` fragte `isConnected` zuerst und
        /// malte grün. Derselbe Zustand las sich auf zwei Flächen gegensätzlich.
        /// `surfaceStatus` ist jetzt die einzige Ableitung.
        @MainActor
        @Suite("HKReadinessStore.surfaceStatus — eine Ableitung für jede Statusanzeige")
        struct HKReadinessSurfaceStatusTests {
            private static func makeStore(userID: String) throws -> HKReadinessStore {
                let keychain = InMemoryKeychain()
                try keychain.setString(userID, forKey: KeychainKey.userID)
                // swiftlint:disable:next force_unwrapping
                let defaults = UserDefaults(suiteName: "hl.tests.\(UUID().uuidString)")!
                return HKReadinessStore(
                    healthKit: nil,
                    backgroundSync: StubBackgroundSyncCoordinator(),
                    keychain: keychain,
                    defaults: defaults
                )
            }

            @Test("Vor dem ersten refresh() → .checking")
            func unknownIsChecking() throws {
                let store = try Self.makeStore(userID: "surface-unknown")
                #expect(store.surfaceStatus == .checking)
            }

            @Test("Nie eingerichtet → .notConnected (neutral, nicht rot)")
            func neverRequestedIsNotConnected() async throws {
                let service = MutableWriteStatusService(statuses: [:])
                let keychain = InMemoryKeychain()
                try keychain.setString("surface-fresh", forKey: KeychainKey.userID)
                // swiftlint:disable:next force_unwrapping
                let defaults = try #require(UserDefaults(suiteName: "hl.tests.\(UUID().uuidString)"))
                let store = HKReadinessStore(
                    healthKit: service,
                    backgroundSync: StubBackgroundSyncCoordinator(),
                    keychain: keychain,
                    defaults: defaults
                )
                await store.refresh()
                #expect(store.state == .notRequested)
                #expect(store.surfaceStatus == .notConnected)
            }

            @Test("Betreiber-Fall: teilweise erteilt → .receiving, niemals ein Fehlerzustand")
            func partiallyGrantedReadsAsReceiving() async throws {
                let service = MutableWriteStatusService(statuses: [
                    MutableWriteStatusService.bodyMassID: .sharingAuthorized,
                    MutableWriteStatusService.bloodGlucoseID: .sharingDenied,
                    MutableWriteStatusService.oxygenSaturationID: .sharingDenied
                ])
                let keychain = InMemoryKeychain()
                try keychain.setString("surface-partial", forKey: KeychainKey.userID)
                // swiftlint:disable:next force_unwrapping
                let defaults = try #require(UserDefaults(suiteName: "hl.tests.\(UUID().uuidString)"))
                let store = HKReadinessStore(
                    healthKit: service,
                    backgroundSync: StubBackgroundSyncCoordinator(),
                    keychain: keychain,
                    defaults: defaults
                )
                await store.refresh()

                guard case .partiallyGranted = store.state else {
                    Issue.record("Vorbedingung: erwartet .partiallyGranted, war \(store.state)")
                    return
                }
                // `.partiallyGranted` setzt `hasRequestedAuthorization` voraus,
                // und damit ist der Empfang eingerichtet — die Verbindung ist in
                // Ordnung, egal was beim Zurückschreiben fehlt.
                #expect(store.surfaceStatus == .receiving)
                #expect(store.surfaceStatus != .declined)
            }

            @Test("Alles abgelehnt und nichts angekommen → .declined (der einzige rote Fall)")
            func deniedWithoutSyncIsDeclined() async throws {
                let service = MutableWriteStatusService(statuses: [
                    MutableWriteStatusService.bodyMassID: .sharingDenied,
                    MutableWriteStatusService.bloodGlucoseID: .sharingDenied,
                    MutableWriteStatusService.oxygenSaturationID: .sharingDenied
                ])
                let keychain = InMemoryKeychain()
                try keychain.setString("surface-denied", forKey: KeychainKey.userID)
                // swiftlint:disable:next force_unwrapping
                let defaults = try #require(UserDefaults(suiteName: "hl.tests.\(UUID().uuidString)"))
                let store = HKReadinessStore(
                    healthKit: service,
                    backgroundSync: StubBackgroundSyncCoordinator(),
                    keychain: keychain,
                    defaults: defaults
                )
                store.markAuthorizationRequested()
                await store.refresh()
                #expect(store.state == .denied)
                #expect(store.surfaceStatus == .declined)

                // Sobald nachweislich Daten ankommen, ist die Verbindung in
                // Ordnung — auch bei komplett verweigertem Zurückschreiben.
                store.noteSuccessfulSync(at: Date(timeIntervalSince1970: 1_715_673_600))
                #expect(store.surfaceStatus == .receiving)
            }

            @Test("missingWriteTypeIdentifiers spiegelt genau die .partiallyGranted-Liste")
            func missingIdentifiersMirrorState() async throws {
                let service = MutableWriteStatusService(statuses: [
                    MutableWriteStatusService.bodyMassID: .sharingAuthorized,
                    MutableWriteStatusService.bloodGlucoseID: .sharingDenied,
                    MutableWriteStatusService.oxygenSaturationID: .notDetermined
                ])
                let keychain = InMemoryKeychain()
                try keychain.setString("surface-missing", forKey: KeychainKey.userID)
                // swiftlint:disable:next force_unwrapping
                let defaults = try #require(UserDefaults(suiteName: "hl.tests.\(UUID().uuidString)"))
                let store = HKReadinessStore(
                    healthKit: service,
                    backgroundSync: StubBackgroundSyncCoordinator(),
                    keychain: keychain,
                    defaults: defaults
                )
                await store.refresh()

                #expect(store.missingWriteTypeIdentifiers == [
                    MutableWriteStatusService.bloodGlucoseID,
                    MutableWriteStatusService.oxygenSaturationID
                ].sorted())
            }
        }

        // MARK: - Transparenzfläche: angefragt ≠ erlaubt

        /// **H1 — „Ich kann nicht sehen was freigegeben ist oder so.“**
        ///
        /// Die Transparenzseite listete, was die App *anfragt*. Diese Tests
        /// nageln fest, dass die fehlenden Typen dort sichtbar werden — mit
        /// lesbaren Namen aus derselben Quelle wie die Liste selbst — und dass
        /// die Seite nichts über Lesezugriff behauptet.
        @Suite("SettingsHealthAccessScreen — erteilter Zustand pro Typ (H1)")
        struct SettingsHealthAccessStatusTests {
            @Test("Fehlende Schreibtypen erscheinen sichtbar als nicht erteilt")
            func missingTypesAreVisiblyNotGranted() {
                let allowed = HKQuantityType(.bodyMass).identifier
                let denied = HKQuantityType(.bloodGlucose).identifier
                let undecided = HKQuantityType(.oxygenSaturation).identifier
                let optIn = "HKCategoryTypeIdentifierMenstrualFlow" // außerhalb des Default-Sets

                let rows = SettingsHealthAccessScreen.rows(
                    identifiers: [allowed, denied, undecided, optIn],
                    statuses: [
                        allowed: .sharingAuthorized,
                        denied: .sharingDenied,
                        undecided: .notDetermined
                    ],
                    showsStatus: true
                )

                #expect(rows.count == 4)
                // Sortierung nach Anzeigename, nicht nach Set-Iteration.
                #expect(rows.map(\.name) == rows.map(\.name).sorted())
                // Jede Zeile trägt einen lesbaren Namen, keinen HK-Identifier.
                #expect(rows.allSatisfy { !$0.name.hasPrefix("HK") })

                let byId = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
                #expect(byId[allowed]?.status == .sharingAuthorized)
                #expect(byId[denied]?.status == .sharingDenied)
                #expect(byId[undecided]?.status == .notDetermined)
                // Opt-in-Typ außerhalb des Default-Sets: die App hat keinen
                // Status — sie sagt „nicht bekannt“ statt zu raten.
                #expect(byId[optIn]?.status == nil)
            }

            @Test("Lesezeilen zeigen keinen Zustand — die Begründung steht einmal in der Intro-Karte")
            func readRowsCarryNoStatus() {
                let rows = SettingsHealthAccessScreen.rows(
                    identifiers: [HKQuantityType(.heartRate).identifier],
                    statuses: [:],
                    showsStatus: false
                )
                #expect(rows.count == 1)
                #expect(rows[0].showsStatus == false)
            }

            @Test("Nur der erteilte Zustand ist positiv gefärbt; kein Zustand ist ein Fehler")
            func onlyGrantedIsPositive() {
                #expect(SettingsHealthAccessScreen.statusDescriptor(for: .sharingAuthorized).isGranted)
                #expect(!SettingsHealthAccessScreen.statusDescriptor(for: .sharingDenied).isGranted)
                #expect(!SettingsHealthAccessScreen.statusDescriptor(for: .notDetermined).isGranted)
                #expect(!SettingsHealthAccessScreen.statusDescriptor(for: nil).isGranted)

                // Vier unterscheidbare Worte + Zeichen — „nicht erlaubt“ und
                // „nicht bekannt“ dürfen nicht zusammenfallen.
                let titles = [
                    SettingsHealthAccessScreen.statusDescriptor(for: .sharingAuthorized).title,
                    SettingsHealthAccessScreen.statusDescriptor(for: .sharingDenied).title,
                    SettingsHealthAccessScreen.statusDescriptor(for: .notDetermined).title,
                    SettingsHealthAccessScreen.statusDescriptor(for: nil).title
                ]
                #expect(Set(titles).count == 4)
                // Kein Warn-/Fehlerzeichen: ein nicht erteilter Schreibtyp ist
                // eine Entscheidung des Nutzers, kein Defekt.
                let symbols = [
                    SettingsHealthAccessScreen.statusDescriptor(for: .sharingDenied).symbol,
                    SettingsHealthAccessScreen.statusDescriptor(for: .notDetermined).symbol,
                    SettingsHealthAccessScreen.statusDescriptor(for: nil).symbol
                ]
                #expect(!symbols.contains { $0.hasPrefix("exclamationmark") })
            }
        }

    #endif

#endif
