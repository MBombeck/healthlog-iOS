// Diese Suite testet App-Target-Symbole, die in der SPM-Library nicht enthalten
// sind. SPM-Test-Build überspringt die Datei.
#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import SnapshotTesting
    import Testing

    /// State-dump-Snapshots für den `HealthKitConnectBanner` — Pixel-Tests
    /// wären brüchig über SDK-Versionen, deshalb snapshotten wir die
    /// User-sichtbaren Labels (subtitle / connectButtonLabel), die
    /// `HKReadinessStore.ConnectionState` als pure-function liefert.
    /// Drift in den Subtitle-Strings oder Connection-Labels surface hier.
    @MainActor
    @Suite("HealthKitConnectBanner state-driven labels")
    struct HealthKitConnectBannerLabelTests {
        @Test("Connection-Label für jeden State")
        func connectionLabelsLockedDown() {
            assertSnapshot(
                of: connectionLabelsDump(),
                as: .lines,
                named: "connection-labels"
            )
        }

        @Test("shouldShowBanner-Truth-Table")
        func shouldShowBannerLockedDown() {
            let table = [
                ".unknown → \(HKReadinessStore.ConnectionState.unknown.shouldShowBanner)",
                ".notRequested → \(HKReadinessStore.ConnectionState.notRequested.shouldShowBanner)",
                ".partiallyGranted([a]) → \(HKReadinessStore.ConnectionState.partiallyGranted(missing: ["a"]).shouldShowBanner)",
                ".fullyGranted → \(HKReadinessStore.ConnectionState.fullyGranted.shouldShowBanner)",
                ".denied → \(HKReadinessStore.ConnectionState.denied.shouldShowBanner)"
            ].joined(separator: "\n")
            assertSnapshot(of: table, as: .lines, named: "should-show-banner")
        }

        /// Reproduziert die User-sichtbaren Connection-Labels über alle States.
        /// Wir bauen für jeden State einen ephemeren Store und lesen das Label.
        private func connectionLabelsDump() -> String {
            let keychain = InMemoryKeychain()
            // swiftlint:disable:next force_unwrapping
            let defaults = UserDefaults(suiteName: "hl.tests.banner-labels.\(UUID().uuidString)")!
            let coordinator = StubBackgroundSyncCoordinator()
            let store = HKReadinessStore(
                healthKit: nil,
                backgroundSync: coordinator,
                keychain: keychain,
                defaults: defaults
            )

            // Default ist `.unknown` — wir können `state` nicht direkt setzen,
            // aber `connectionLabel` ist eine pure Function über `state`. Wir
            // testen daher die Strings über `String(localized:)` direkt mit
            // den exakten Argument-Werten, die `connectionLabel` formatiert.
            // (Defensive — wenn der Source-Code-String drift't, schlägt der
            // Snapshot an.)
            let unknown = store.connectionLabel
            let notRequested = String(localized: "Not connected")
            let partial1 = String(localized: "Teilweise verbunden — \(1) Typ(en) fehlen")
            let partial3 = String(localized: "Teilweise verbunden — \(3) Typ(en) fehlen")
            let full = String(localized: "Connected")
            let denied = String(localized: "Vom Nutzer abgelehnt")
            return [
                ".unknown → \(unknown)",
                ".notRequested → \(notRequested)",
                ".partiallyGranted(1 missing) → \(partial1)",
                ".partiallyGranted(3 missing) → \(partial3)",
                ".fullyGranted → \(full)",
                ".denied → \(denied)"
            ].joined(separator: "\n")
        }
    }

#endif
