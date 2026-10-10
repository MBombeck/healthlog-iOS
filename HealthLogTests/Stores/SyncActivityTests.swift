// App-Target-Symbole (`SyncStateStore`, `HKSyncDiagnostics`) — nicht in der SPM-Library.
#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing
    import UIKit

    /// **U1 (#16) — eine Quelle für „zuletzt synchronisiert".**
    ///
    /// Vorher schrieb nur der Pull-to-Refresh-Handshake `lastHandshakeAt`. Was
    /// Apple Health im Hintergrund hochlud (Beobachter, Tagesstatistik,
    /// Trainings, Hintergrund-Wakes), kam in keiner Zeitangabe an. Diese Suites
    /// pinnen, dass jeder Weg, der eine Server-Annahme hört, die Zeit bewegt —
    /// und dass Wege ohne Annahme es nicht tun.
    @MainActor
    @Suite("U1 — SyncStateStore.lastSync liest auch Apple-Health-Uploads", .serialized, .mockURLSession)
    struct SyncStateStoreLastSyncTests {
        // swiftlint:disable:next large_tuple
        private func makeDiagnostics() -> (HKSyncDiagnostics, UserDefaults, String) {
            let suite = "u1.sync-activity.\(UUID().uuidString)"
            // swiftlint:disable:next force_unwrapping
            let defaults = UserDefaults(suiteName: suite)!
            return (HKSyncDiagnostics.makeForTesting(defaults: defaults), defaults, suite)
        }

        private func makeStore(_ diagnostics: HKSyncDiagnostics?) -> SyncStateStore {
            let env = AppEnvironment(
                // swiftlint:disable:next force_unwrapping
                baseURL: URL(string: "https://test.healthlog.local")!,
                bundleID: "dev.healthlog.app",
                appVersion: "1.1.1",
                buildNumber: "1"
            )
            let api = APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
            return SyncStateStore(
                repo: SyncStateRepository(api: api),
                drainConfirmationHold: .seconds(60),
                minimumSyncingHold: .zero,
                doneHold: .zero,
                healthDiagnostics: diagnostics
            )
        }

        @Test("Ein vom Server angenommener Beobachter-Upload bewegt die Zeit")
        func observerUploadMovesLastSync() {
            let (diagnostics, defaults, suite) = makeDiagnostics()
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = makeStore(diagnostics)
            #expect(store.lastSync == nil)
            let at = Date(timeIntervalSince1970: 1_800_000_000)
            diagnostics.recordObservation(
                identifier: "HKQuantityTypeIdentifierHeartRate",
                samplesRead: 4,
                samplesUploaded: 3,
                anchorAdvanced: true,
                at: at
            )
            #expect(store.lastSync?.at == at)
            #expect(store.lastHandshakeAt == nil, "der Handshake bleibt, was er ist")
        }

        @Test("Gelesen, aber nichts angenommen, bewegt die Zeit nicht")
        func observationWithoutAcceptanceDoesNotMove() {
            let (diagnostics, defaults, suite) = makeDiagnostics()
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = makeStore(diagnostics)
            diagnostics.recordObservation(
                identifier: "HKQuantityTypeIdentifierHeartRate",
                samplesRead: 4,
                samplesUploaded: 0,
                samplesParked: 4,
                anchorAdvanced: false
            )
            diagnostics.recordWorkoutResponse(accepted: 0, skipped: 2, completeAcceptance: false)
            #expect(store.lastSync == nil)
        }

        @Test("Tagesstatistik und Trainings bewegen die Zeit")
        func statsAndWorkoutsMoveLastSync() {
            let (diagnostics, defaults, suite) = makeDiagnostics()
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = makeStore(diagnostics)
            let first = Date(timeIntervalSince1970: 1_800_000_000)
            diagnostics.recordStatsAction(identifier: "HKQuantityTypeIdentifierStepCount", posted: 1, reposted: 0, at: first)
            #expect(store.lastSync?.at == first)
            let second = first.addingTimeInterval(120)
            diagnostics.recordWorkoutResponse(accepted: 2, skipped: 0, completeAcceptance: true, at: second)
            #expect(store.lastSync?.at == second)
        }

        @Test("Ein orchestrierter Pass zählt nur, wenn er Einträge abgeschlossen hat")
        func orchestratedPassCountsOnlyWithSettledItems() {
            let (diagnostics, defaults, suite) = makeDiagnostics()
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = makeStore(diagnostics)
            diagnostics.recordHealthSyncPass(Self.pass(settled: 0), at: Date(timeIntervalSince1970: 1_800_000_000))
            #expect(store.lastSync == nil, "`ran` ohne Zählung ist kein Beweis")
            let at = Date(timeIntervalSince1970: 1_800_000_600)
            diagnostics.recordHealthSyncPass(Self.pass(settled: 5), at: at)
            #expect(store.lastSync?.at == at)
        }

        @Test("Ein Hintergrund-Upload nach dem Handshake trägt Zeit und Kanal")
        func backgroundUploadAfterHandshakeWins() async throws {
            let (diagnostics, defaults, suite) = makeDiagnostics()
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = makeStore(diagnostics)
            MockURLProtocol.install { req in
                let body = Data(#"""
                {"data":{"userId":"usr_u1","timezone":"Europe/Berlin",
                  "lastSyncedAt":"2026-10-04T08:00:00Z","serverNow":"2026-10-04T08:00:01Z",
                  "measurements":{"lastUpdatedAt":"2026-10-04T08:00:00Z","liveCount":1,"tombstonedCount":0}
                },"error":null}
                """#.utf8)
                // swiftlint:disable:next force_unwrapping
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
            }
            await store.handshake()
            let handshake = try #require(store.lastHandshakeAt)
            #expect(store.lastSync == SyncActivity(at: handshake, channel: .foreground))

            let later = handshake.addingTimeInterval(3600)
            diagnostics.noteServerAcceptance(at: later, channel: .background)
            #expect(store.lastSync == SyncActivity(at: later, channel: .background))
        }

        @Test("Eine verspätete ältere Annahme dreht die Zeit nicht zurück")
        func acceptanceIsMonotonic() {
            let (diagnostics, defaults, suite) = makeDiagnostics()
            defer { defaults.removePersistentDomain(forName: suite) }
            let newer = Date(timeIntervalSince1970: 1_800_000_600)
            diagnostics.noteServerAcceptance(at: newer, channel: .background)
            diagnostics.noteServerAcceptance(at: newer.addingTimeInterval(-60), channel: .foreground)
            #expect(diagnostics.lastServerAcceptance == SyncActivity(at: newer, channel: .background))
        }

        @Test("Die Annahme überlebt einen Neustart und geht mit dem Abmelden")
        func acceptancePersistsAndResets() {
            let (diagnostics, defaults, suite) = makeDiagnostics()
            defer { defaults.removePersistentDomain(forName: suite) }
            let at = Date(timeIntervalSince1970: 1_800_000_000)
            diagnostics.noteServerAcceptance(at: at, channel: .background)
            let relaunched = HKSyncDiagnostics.makeForTesting(defaults: defaults)
            #expect(relaunched.lastServerAcceptance == SyncActivity(at: at, channel: .background))
            relaunched.reset()
            #expect(relaunched.lastServerAcceptance == nil)
            #expect(HKSyncDiagnostics.makeForTesting(defaults: defaults).lastServerAcceptance == nil)
        }

        @Test("Ein echter Outbox-Abfluss zählt, ein Dead-Letter-Abwurf nimmt ihn zurück")
        func outboxDrainCountsUnlessItWasADrop() {
            let store = makeStore(nil)
            store.noteOutboxPending(2)
            store.noteOutboxPending(0)
            #expect(store.lastSync?.channel == .foreground)

            // Same transition, but the replay reports the rows as dead-lettered
            // after the count broadcast: the stamp goes back to "before".
            let dropped = makeStore(nil)
            dropped.noteOutboxPending(1)
            dropped.noteOutboxPending(0)
            dropped.noteDeadLettered(1)
            #expect(dropped.lastSync == nil)
        }

        @Test("Abmelden leert die Outbox-Hälfte")
        func logoutClearsOutboxStamp() {
            let store = makeStore(nil)
            store.noteOutboxPending(1)
            store.noteOutboxPending(0)
            store.clearOnLogout()
            #expect(store.lastSync == nil)
        }

        static func pass(settled: Int) -> HealthSyncPassSnapshot {
            HealthSyncPassSnapshot(
                trigger: "processing",
                startedAt: Date(timeIntervalSince1970: 1_800_000_000),
                durationMilliseconds: 10,
                isComplete: settled > 0,
                heldItemCount: 0,
                omittedCapabilities: [],
                capabilities: [
                    .init(
                        capability: "workoutImport",
                        disposition: settled > 0 ? "succeeded" : "ran",
                        itemsSubmitted: settled,
                        itemsSettled: settled,
                        itemsHeld: 0,
                        failure: nil,
                        holdReason: nil
                    )
                ]
            )
        }
    }

    /// **U1 (#16) — wann ein Zustand Aufmerksamkeit braucht.** Nur für Zustände, die
    /// Aufmerksamkeit brauchen; ein gesundes Konto zeigt nichts.
    @Suite("U1 — SyncAttention.resolve")
    struct SyncAttentionResolveTests {
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        private func resolve(
            inFlight: Bool = false,
            failed: Int = 0,
            handshakeFailed: Bool = false,
            queued: Int = 0,
            queuedSince: Date? = nil,
            lastSync: SyncActivity? = nil
        ) -> SyncAttention? {
            SyncAttention.resolve(
                isInFlight: inFlight,
                failedWriteCount: failed,
                handshakeFailed: handshakeFailed,
                queuedWriteCount: queued,
                queuedSince: queuedSince,
                lastSync: lastSync,
                now: now
            )
        }

        @Test("Gesund heißt: nichts zu zeigen")
        func healthyHasNoBadge() {
            #expect(resolve() == nil)
            #expect(resolve(lastSync: SyncActivity(at: now.addingTimeInterval(-300), channel: .background)) == nil)
        }

        @Test("Verlorene Einträge gehen allem vor, auch einem laufenden Sync")
        func failedWritesOutrankEverything() {
            #expect(resolve(inFlight: true, failed: 3, handshakeFailed: true, queued: 2) == .failedWrites(3))
        }

        @Test("Während eines Syncs schweigt der Zustand sonst")
        func inFlightSilencesTheRest() {
            #expect(resolve(inFlight: true, handshakeFailed: true) == nil)
            #expect(resolve(inFlight: true, queued: 2, queuedSince: now.addingTimeInterval(-60)) == nil)
        }

        @Test("Fehlgeschlagener Handshake vor Warteschlange vor veraltet")
        func order() {
            let old = SyncActivity(at: now.addingTimeInterval(-2 * 86400), channel: .foreground)
            #expect(resolve(handshakeFailed: true, queued: 1, queuedSince: now.addingTimeInterval(-60), lastSync: old) == .failed)
            #expect(resolve(queued: 1, queuedSince: now.addingTimeInterval(-60), lastSync: old) == .queued(1))
            #expect(resolve(lastSync: old) == .stale(since: old.at))
        }

        @Test("Eine Warteschlange zählt erst nach zehn Sekunden")
        func queuedNeedsToWait() {
            #expect(resolve(queued: 2, queuedSince: now.addingTimeInterval(-3)) == nil)
            #expect(resolve(queued: 2, queuedSince: now.addingTimeInterval(-10)) == .queued(2))
        }

        @Test("Veraltet ab mehr als einem Tag, nie ohne jede Synchronisierung")
        func staleThreshold() {
            let justInside = SyncActivity(at: now.addingTimeInterval(-86400), channel: .background)
            let justOutside = SyncActivity(at: now.addingTimeInterval(-86401), channel: .background)
            #expect(resolve(lastSync: justInside) == nil)
            #expect(resolve(lastSync: justOutside) == .stale(since: justOutside.at))
            #expect(resolve(lastSync: nil) == nil)
        }
    }

    /// **INT-L (1.1.1) — ein Platz neben dem Avatar.** Kein Badge mehr auf
    /// dem Avatar: Was Aufmerksamkeit braucht, steht als ruhiges Symbol im
    /// selben Platz wie der Sync-Glyph. Ein laufender Sync und sein Häkchen
    /// gehen vor; danach bleibt das Zustandssymbol, bis der Zustand weg ist.
    @Suite("INT-L — SyncSlotGlyph")
    struct SyncSlotGlyphTests {
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        @Test("Sync und Häkchen gehen jedem Zustand vor, danach bleibt der Zustand")
        func precedence() {
            let stale = SyncAttention.stale(since: now.addingTimeInterval(-2 * 86400))
            #expect(SyncSlotGlyph.resolve(indicator: .syncing, attention: .failedWrites(2)) == .syncing)
            #expect(SyncSlotGlyph.resolve(indicator: .done, attention: .queued(1)) == .done)
            #expect(SyncSlotGlyph.resolve(indicator: nil, attention: .failed) == .attention(.failed))
            #expect(SyncSlotGlyph.resolve(indicator: nil, attention: stale) == .attention(stale))
            #expect(SyncSlotGlyph.resolve(indicator: nil, attention: nil) == nil)
        }

        @Test("Jeder Zustand hat ein eigenes, vorhandenes SF Symbol")
        func symbolsAreDistinctAndExist() {
            let glyphs: [SyncSlotGlyph] = [
                .syncing, .done,
                .attention(.failedWrites(1)), .attention(.failed),
                .attention(.queued(1)), .attention(.stale(since: now))
            ]
            let symbols = glyphs.map(HLSyncActivityGlyph.symbol(for:))
            #expect(Set(symbols).count == glyphs.count, "\(symbols)")
            for symbol in symbols {
                #expect(UIImage(systemName: symbol) != nil, "\(symbol) gibt es nicht")
            }
        }

        @Test("Der Store: verlorene Einträge vor fehlgeschlagenem Sync, beides bleibt stehen", .mockURLSession)
        @MainActor
        func storeWalksTheSlot() async {
            let store = SyncIndicatorGlyphTests.makeStore()
            #expect(store.slotGlyph() == nil, "gesund und ruhend: nichts")
            store.noteDeadLettered(2)
            #expect(store.slotGlyph() == .attention(.failedWrites(2)))
            MockURLProtocol.install { req in
                // swiftlint:disable:next force_unwrapping
                (HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
            }
            await store.handshake()
            #expect(store.slotGlyph() == .attention(.failedWrites(2)), "verlorene Einträge bleiben sichtbar")
            store.clearFailedDrop()
            #expect(store.slotGlyph() == .attention(.failed))
        }
    }

    /// **U1 (#16) — die Phasen des Glyphs oben.** Es liest dieselbe
    /// Phasenmaschine wie Fußzeile und Pull-to-Refresh-Häkchen.
    @Suite("U1 — SyncIndicatorGlyph.resolve")
    struct SyncIndicatorGlyphTests {
        @MainActor
        static func makeStore() -> SyncStateStore {
            let env = AppEnvironment(
                // swiftlint:disable:next force_unwrapping
                baseURL: URL(string: "https://test.healthlog.local")!,
                bundleID: "dev.healthlog.app",
                appVersion: "1.1.1",
                buildNumber: "1"
            )
            let api = APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
            return SyncStateStore(
                repo: SyncStateRepository(api: api),
                minimumSyncingHold: .zero,
                doneHold: .seconds(30)
            )
        }

        @Test("syncing → dreht, done → Häkchen, idle → weg")
        func phaseMapping() {
            #expect(SyncIndicatorGlyph.resolve(phase: .syncing, isLoading: false) == .syncing)
            #expect(SyncIndicatorGlyph.resolve(phase: .done, isLoading: false) == .done)
            #expect(SyncIndicatorGlyph.resolve(phase: .idle, isLoading: false) == nil)
            #expect(SyncIndicatorGlyph.resolve(phase: .idle, isLoading: true) == .syncing)
        }

        @Test("Der Store läuft syncing → done → weg; ein Fehler endet ohne Häkchen", .mockURLSession)
        @MainActor
        func storeWalksTheGlyph() async {
            let store = Self.makeStore()
            #expect(store.indicatorGlyph == nil)
            MockURLProtocol.install { req in
                let body = Data(#"""
                {"data":{"userId":"usr_u1","timezone":"Europe/Berlin",
                  "lastSyncedAt":"2026-10-04T08:00:00Z","serverNow":"2026-10-04T08:00:01Z",
                  "measurements":{"lastUpdatedAt":"2026-10-04T08:00:00Z","liveCount":1,"tombstonedCount":0}
                },"error":null}
                """#.utf8)
                // swiftlint:disable:next force_unwrapping
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
            }
            await store.handshake()
            #expect(store.indicatorGlyph == .done, "Erfolg: Häkchen für die done-Phase")
            #expect(store.attention() == nil)

            MockURLProtocol.install { req in
                // swiftlint:disable:next force_unwrapping
                (HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
            }
            await store.handshake()
            #expect(store.indicatorGlyph == nil, "Fehler: kein Häkchen")
            #expect(store.attention() == .failed)
        }
    }
#endif
