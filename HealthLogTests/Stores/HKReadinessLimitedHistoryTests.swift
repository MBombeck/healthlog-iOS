// Diese Suite testet App-Target-Symbole (`HKReadinessStore`), die in der
// SPM-Library nicht enthalten sind.
#if !SWIFT_PACKAGE && canImport(HealthKit)

    import AppIntents
    import Foundation
    import HealthKit
    @testable import HealthLog
    import Testing

    /// **1.4 / iOS 27 — the one visible trace of a limited history, and Siri
    /// on a locked iPhone.**
    ///
    /// Settings › Apple Health shows one line while the person lets HealthLog
    /// read only a recent window; the readiness store carries the date. And the
    /// two intents that read medication data aloud ask for Face ID or the
    /// passcode first, while the writing ones stay usable from the lock screen.
    @MainActor
    @Suite("Limited history in Settings and Siri on a locked iPhone (1.4)")
    struct HKReadinessLimitedHistoryTests {
        private static let boundary = Date(timeIntervalSince1970: 1_790_000_000)

        private static func makeStore(service: some HealthKitServiceProtocol) throws -> HKReadinessStore {
            let keychain = InMemoryKeychain()
            try keychain.setString("user-limited", forKey: KeychainKey.userID)
            return try HKReadinessStore(
                healthKit: service,
                backgroundSync: StubBackgroundSyncCoordinator(),
                keychain: keychain,
                defaults: #require(UserDefaults(suiteName: "a3.limited.\(UUID().uuidString)"))
            )
        }

        @Test("a limited window reaches the store on refresh")
        func limitedWindowIsShown() async throws {
            let store = try Self.makeStore(service: LimitedHistoryService(start: Self.boundary))
            #expect(store.limitedHistoryStart == nil)
            await store.refresh()
            #expect(store.limitedHistoryStart == Self.boundary)
        }

        @Test("full access shows nothing")
        func fullAccessShowsNothing() async throws {
            let store = try Self.makeStore(service: LimitedHistoryService(start: nil))
            await store.refresh()
            #expect(store.limitedHistoryStart == nil)
        }

        @Test("a service that cannot ask the system shows nothing")
        func defaultServiceShowsNothing() async throws {
            let store = try Self.makeStore(service: MutableWriteStatusService(statuses: [:]))
            await store.refresh()
            #expect(store.limitedHistoryStart == nil)
        }

        @Test("the Settings line exists in English and German and keeps its date argument")
        func settingsLineIsLocalized() throws {
            let key = "settings.applehealth.limitedHistory %@"
            for language in ["en", "de"] {
                let path = try #require(Bundle.main.path(forResource: language, ofType: "lproj"))
                let bundle = try #require(Bundle(path: path))
                let value = bundle.localizedString(forKey: key, value: "<missing>", table: nil)
                #expect(value != "<missing>" && value != key, "\(language) has the line")
                #expect(value.components(separatedBy: "%@").count == 2, "\(language) keeps one date")
            }
        }

        // MARK: - Siri on a locked iPhone

        @Test("the two reading intents ask for authentication first")
        func readingIntentsRequireAuthentication() {
            #expect(DidITakeMedicationIntent.authenticationPolicy == .requiresAuthentication)
            #expect(MedicationComplianceQueryIntent.authenticationPolicy == .requiresAuthentication)
        }

        @Test("the writing intents stay usable from the lock screen")
        func writingIntentsStayOpen() {
            #expect(MarkMedicationTakenIntent.authenticationPolicy == .alwaysAllowed)
            #expect(MarkNextDoseTakenIntent.authenticationPolicy == .alwaysAllowed)
            #expect(LogMoodIntent.authenticationPolicy == .alwaysAllowed)
        }

        @Test("the next-dose confirmation follows the lock-screen name switch")
        func nextDoseConfirmationHidesTheName() {
            #expect(MarkNextDoseTakenIntent.confirmation(medicationName: "Sertralin", hidesName: true).key
                == "Marked your next dose as taken.")
            #expect(MarkNextDoseTakenIntent.confirmation(medicationName: "Sertralin", hidesName: false).key
                == "Marked %@ as taken.")
        }
    }

    /// A `HealthKitServiceProtocol` double that reports a fixed limited-history
    /// start and nothing else of interest.
    final class LimitedHistoryService: HealthKitServiceProtocol, @unchecked Sendable {
        private let start: Date?

        init(start: Date?) {
            self.start = start
        }

        func limitedHistoryStart() async -> Date? {
            start
        }

        func isAvailable() -> Bool {
            true
        }

        func authorizationStatus(for _: HKObjectType) -> HKAuthorizationStatus {
            .notDetermined
        }

        func authorizationStatuses(for types: Set<HKSampleType>) -> [String: HKReadinessStore.AuthStatus] {
            Dictionary(uniqueKeysWithValues: types.map { ($0.identifier, HKReadinessStore.AuthStatus.sharingAuthorized) })
        }

        func requestAuthorization(read _: Set<HKObjectType>, write _: Set<HKSampleType>) async throws {}
        func resetAuthDisabledTypes() async {}

        func defaultReadTypes() -> Set<HKObjectType> {
            [HKQuantityType(.bodyMass)]
        }

        func defaultWriteTypes() -> Set<HKSampleType> {
            [HKQuantityType(.bodyMass)]
        }

        func writeMeasurement(_: HealthLog.Measurement) async throws {}
        func writeMoodEntry(_: MoodEntry) async throws {}
        func startBackgroundDeliveries() async throws {}
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
