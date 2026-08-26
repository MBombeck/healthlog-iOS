import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// **GH #74 — der Schalter, an dem die EKG-Übernahme hängt.**
///
/// Die Entscheidung, die hier festgenagelt wird: der EKG-Lesetyp gehört NICHT
/// ins Standardpaket beim Onboarding. Er ist die sensibelste Fläche des
/// HealthKit-Speichers, sein einziger Zweck ist ein Server-Schreibvorgang, und
/// bis Server v1.35.3 gab es dafür überhaupt kein Ziel. Also: geräte-lokaler
/// Schalter, standardmäßig aus, Berechtigungsfrage genau im Moment des
/// Einschaltens.
@Suite("EcgHealthSyncStore — Opt-in, Abmeldung, ehrlicher Schalterzustand")
@MainActor
struct EcgHealthSyncStoreTests {
    private func isolatedDefaults() -> UserDefaults {
        let suite = "ecg.store.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test("Standardmäßig aus — niemand wird ungefragt nach seinem EKG gefragt")
    func offByDefault() {
        let store = EcgHealthSyncStore(healthKit: nil, sync: nil, defaults: isolatedDefaults())
        #expect(!store.enabled)
    }

    @Test("Einschalten fragt die Berechtigung an und startet einen ersten Durchlauf")
    func enablingRequestsAuthorizationThenSyncs() async {
        let writer = SpyHealthKitWriter()
        let sync = SpyEcgSync()
        let store = EcgHealthSyncStore(healthKit: writer, sync: sync, defaults: isolatedDefaults())
        await store.setEnabled(true)
        #expect(store.enabled)
        #expect(writer.ecgAuthorizationRequests == 1)
        #expect(sync.triggerCount == 1, "der erste Durchlauf holt die ganze Vorgeschichte nach")
    }

    @Test("Eine abgelehnte Berechtigung lässt den Schalter aus — kein Versprechen, das nicht laufen kann")
    func deniedAuthorizationKeepsSwitchOff() async {
        let writer = SpyHealthKitWriter(failAuthorization: true)
        let sync = SpyEcgSync()
        let defaults = isolatedDefaults()
        let store = EcgHealthSyncStore(healthKit: writer, sync: sync, defaults: defaults)
        await store.setEnabled(true)
        #expect(!store.enabled)
        #expect(!defaults.bool(forKey: EcgHealthSyncStore.prefKey))
        #expect(sync.triggerCount == 0)
    }

    @Test("Ausschalten räumt den Cursor weg, damit ein späteres Einschalten nichts stillschweigend überspringt")
    func disablingResetsTheCursor() async {
        let writer = SpyHealthKitWriter()
        let sync = SpyEcgSync()
        let resets = Counter()
        let store = EcgHealthSyncStore(
            healthKit: writer,
            sync: sync,
            resetAnchor: { resets.increment() },
            defaults: isolatedDefaults()
        )
        await store.setEnabled(true)
        await store.setEnabled(false)
        #expect(!store.enabled)
        #expect(resets.value == 1)
    }

    @Test("Der Schalter überlebt den Neustart — die Wahl gehört dem Nutzer, nicht dem Prozess")
    func prefSurvivesRelaunch() async {
        let defaults = isolatedDefaults()
        let first = EcgHealthSyncStore(healthKit: SpyHealthKitWriter(), sync: SpyEcgSync(), defaults: defaults)
        await first.setEnabled(true)
        let second = EcgHealthSyncStore(healthKit: SpyHealthKitWriter(), sync: SpyEcgSync(), defaults: defaults)
        #expect(second.enabled)
    }

    @Test("activateIfEnabled läuft nur bei eingeschaltetem Schalter")
    func activateOnlyWhenEnabled() async {
        let sync = SpyEcgSync()
        let defaults = isolatedDefaults()
        let off = EcgHealthSyncStore(healthKit: SpyHealthKitWriter(), sync: sync, defaults: defaults)
        await off.activateIfEnabled()
        #expect(sync.triggerCount == 0)

        await off.setEnabled(true)
        #expect(sync.triggerCount == 1)
        await off.activateIfEnabled()
        #expect(sync.triggerCount == 2)
    }

    @Test("Abmelden erzwingt AUS und räumt den Cursor — Einwilligung wird nicht vererbt")
    func logoutForcesOffAndClears() async {
        let defaults = isolatedDefaults()
        let resets = Counter()
        let store = EcgHealthSyncStore(
            healthKit: SpyHealthKitWriter(),
            sync: SpyEcgSync(),
            resetAnchor: { resets.increment() },
            defaults: defaults
        )
        await store.setEnabled(true)
        await store.deactivateOnLogout()
        #expect(!store.enabled)
        #expect(!defaults.bool(forKey: EcgHealthSyncStore.prefKey))
        #expect(resets.value == 1)
        // Und der nächste Nutzer auf demselben Gerät startet aus.
        let next = EcgHealthSyncStore(healthKit: SpyHealthKitWriter(), sync: SpyEcgSync(), defaults: defaults)
        #expect(!next.enabled)
    }

    @Test("Der Koordinator liest denselben Schlüssel, den der Schalter schreibt")
    func coordinatorReadsTheSamePref() async {
        let defaults = isolatedDefaults()
        let store = EcgHealthSyncStore(healthKit: SpyHealthKitWriter(), sync: SpyEcgSync(), defaults: defaults)
        #expect(!EcgHealthSyncStore.isOptedIn(in: defaults))
        await store.setEnabled(true)
        #expect(EcgHealthSyncStore.isOptedIn(in: defaults))
    }
}

// MARK: - Test doubles

private final class SpyEcgSync: EcgSyncing, @unchecked Sendable {
    private let lock = NSLock()
    private var _triggerCount = 0
    var triggerCount: Int {
        lock.withLock { _triggerCount }
    }

    func triggerEcgSync() async {
        lock.withLock { _triggerCount += 1 }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int {
        lock.withLock { _value }
    }

    func increment() {
        lock.withLock { _value += 1 }
    }
}

/// Minimal ``AnyHealthKitWriter`` double — every other requirement comes from
/// the protocol's default no-ops, which is exactly the seam that lets the ECG
/// path be tested without HealthKit.
private final class SpyHealthKitWriter: AnyHealthKitWriter, @unchecked Sendable {
    private let lock = NSLock()
    private var _ecgAuthorizationRequests = 0
    private let failAuthorization: Bool

    init(failAuthorization: Bool = false) {
        self.failAuthorization = failAuthorization
    }

    var ecgAuthorizationRequests: Int {
        lock.withLock { _ecgAuthorizationRequests }
    }

    func requestEcgAuthorizationIfNeeded() async throws {
        lock.withLock { _ecgAuthorizationRequests += 1 }
        if failAuthorization { throw URLError(.userAuthenticationRequired) }
    }

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
    func stopWorkoutImportObserver() async {}
    func resetWorkoutImportObserver() async {}
}

// swiftlint:enable force_unwrapping
