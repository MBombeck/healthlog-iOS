import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

// swiftlint:disable force_unwrapping

/// **CU-21 (2) — die Zusatzfelder von `GET /api/integrations/healthkit`.**
///
/// Server ≥ v1.32.31 legt `lastSyncTrigger`, `lastBackgroundSyncAt`,
/// `syncHealth { verdict, since }` und `metricFreshness[]` bei — **nur im GET,
/// nicht im PATCH-Echo**. Getestet über den echten `SettingsRepository` +
/// `APIClient` über `MockURLProtocol`, damit die Zusicherung am produktiven
/// Decoding-Pfad hängt.
@Suite("CU-21 — GET /api/integrations/healthkit: Sync-Gesundheit", .serialized)
struct HealthKitSyncHealthDecodingTests {
    private static let env = AppEnvironment(
        baseURL: URL(string: "https://test.healthlog.local")!,
        bundleID: "dev.healthlog.app",
        appVersion: "0.1.0",
        buildNumber: "1"
    )

    private func makeRepo() -> SettingsRepository {
        let keychain = InMemoryKeychain()
        try? keychain.setString("token", forKey: KeychainKey.authToken)
        return SettingsRepository(
            api: APIClient(environment: Self.env, keychain: keychain, sessionConfiguration: .mock())
        )
    }

    private func respond(_ json: String) {
        MockURLProtocol.handler = { req in
            let response = HTTPURLResponse(
                url: req.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(json.utf8))
        }
    }

    private static let entriesFragment = """
    "entries":[{"id":"weight","kind":"bodyMass","direction":"bidirectional","enabled":true}]
    """

    // MARK: - Volle Fixture

    @Test("Volle Fixture: Verdict, Zeitanker, Auslöser und Frische kommen an")
    func fullFixtureDecodes() async throws {
        respond("""
        {\(Self.entriesFragment),
         "lastSyncedAt":"2026-07-30T08:00:00.000Z",
         "lastSyncTrigger":"background",
         "lastBackgroundSyncAt":"2026-07-30T07:55:00.000Z",
         "syncHealth":{"verdict":"fresh","since":"2026-07-28T06:00:00.000Z"},
         "metricFreshness":[
            {"type":"weight","lastSeenAt":"2026-07-30T07:55:00.000Z","stale":false},
            {"type":"heart_rate","lastSeenAt":"2026-07-20T07:55:00.000Z","stale":true}]}
        """)

        let config = try await makeRepo().healthKitConfig()

        #expect(config.entries.count == 1)
        #expect(config.lastSyncTrigger == "background")
        #expect(config.lastSyncTriggerKind == .background)
        #expect(config.lastBackgroundSyncAt != nil)
        #expect(config.syncHealth?.verdict == .fresh)
        #expect(config.syncHealth?.since != nil)
        #expect(config.metricFreshness?.count == 2)
        #expect(config.metricFreshness?.last?.type == "heart_rate")
        #expect(config.metricFreshness?.last?.stale == true)
    }

    @Test(
        "Alle acht Vertragswerte des Verdicts dekodieren auf ihren Fall",
        arguments: [
            ("fresh", SyncHealthVerdict.fresh),
            ("stale", .stale),
            ("stalled", .stalled),
            ("failing", .failing),
            ("reauth_required", .reauthRequired),
            ("parked", .parked),
            ("pending_first_sync", .pendingFirstSync),
            ("disconnected", .disconnected)
        ]
    )
    func allEightVerdicts(raw: String, expected: SyncHealthVerdict) async throws {
        respond("""
        {\(Self.entriesFragment),"syncHealth":{"verdict":"\(raw)","since":null}}
        """)

        let config = try await makeRepo().healthKitConfig()

        #expect(config.syncHealth?.verdict == expected)
        #expect(config.syncHealth?.verdict.rawValue == raw)
    }

    // MARK: - Toleranz

    @Test("Ein NEUNTES Verdict kippt nichts — es landet als `.unknown` mit Rohwort")
    func unknownVerdictDoesNotBreakAnything() async throws {
        respond("""
        {\(Self.entriesFragment),
         "lastSyncTrigger":"background",
         "syncHealth":{"verdict":"quarantined_by_ops","since":"2026-07-28T06:00:00.000Z"}}
        """)

        let config = try await makeRepo().healthKitConfig()

        #expect(config.syncHealth?.verdict == .unknown("quarantined_by_ops"))
        // Der Rest der Antwort bleibt intakt — genau das ist der Punkt.
        #expect(config.entries.count == 1)
        #expect(config.lastSyncTrigger == "background")
        // Ein unbekanntes Wort ist NICHT alarmierend: niemand weiß, was es
        // bedeutet, also darf es keine Warnfläche erzeugen.
        #expect(config.syncHealth?.verdict.needsAttention == false)
    }

    @Test("Ein unbekannter Auslöser bleibt roh erhalten, wird aber nicht typisiert")
    func unknownTriggerStaysRaw() async throws {
        respond("""
        {\(Self.entriesFragment),"lastSyncTrigger":"watch_relay"}
        """)

        let config = try await makeRepo().healthKitConfig()

        #expect(config.lastSyncTrigger == "watch_relay")
        #expect(config.lastSyncTriggerKind == nil)
    }

    @Test("Ein älterer Server ohne die Felder dekodiert unverändert")
    func legacyServerPayload() async throws {
        respond("""
        {\(Self.entriesFragment),"lastSyncedAt":"2026-07-30T08:00:00.000Z"}
        """)

        let config = try await makeRepo().healthKitConfig()

        #expect(config.syncHealth == nil)
        #expect(config.lastSyncTrigger == nil)
        #expect(config.lastBackgroundSyncAt == nil)
        // `nil` (Feld unbekannt) ist NICHT dasselbe wie `[]` (Feld bekannt,
        // noch nichts geliefert).
        #expect(config.metricFreshness == nil)
    }

    @Test("`metricFreshness: []` ist Abwesenheit von Lieferungen, nicht Abwesenheit des Feldes")
    func emptyFreshnessIsDistinctFromMissing() async throws {
        respond("""
        {\(Self.entriesFragment),"metricFreshness":[]}
        """)

        let config = try await makeRepo().healthKitConfig()

        #expect(config.metricFreshness != nil)
        #expect(config.metricFreshness?.isEmpty == true)
    }

    @Test("`metricFreshness` führt nur gelieferte Typen — ein fehlender Typ ist kein Nullwert")
    func freshnessListsOnlyDeliveredTypes() async throws {
        respond("""
        {\(Self.entriesFragment),
         "metricFreshness":[{"type":"weight","lastSeenAt":"2026-07-30T07:55:00.000Z","stale":false}]}
        """)

        let config = try await makeRepo().healthKitConfig()

        let freshness = try #require(config.metricFreshness)
        #expect(freshness.map(\.type) == ["weight"])
        // `heart_rate` kommt schlicht nicht vor — es gibt keinen Platzhalter
        // mit lastSeenAt == nil, den eine Fläche als „0" zeichnen könnte.
        #expect(!freshness.contains { $0.type == "heart_rate" })
    }

    // MARK: - PATCH-Body bleibt unverändert

    @Test("Der PATCH-Body trägt weiterhin NUR `entries` + `lastSyncedAt`")
    func patchBodyStaysNarrow() throws {
        let config = HealthKitSyncConfig(
            entries: [HealthKitSyncEntry(id: "weight", kind: "bodyMass", direction: .bidirectional, enabled: true)],
            lastSyncedAt: Date(timeIntervalSince1970: 1_753_862_400),
            lastSyncTrigger: "background",
            lastBackgroundSyncAt: Date(timeIntervalSince1970: 1_753_862_000),
            syncHealth: HealthKitSyncHealth(verdict: .fresh),
            metricFreshness: [MetricFreshness(type: "weight")]
        )

        let data = try JSONEncoder().encode(config)
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(Set(obj.keys) == ["entries", "lastSyncedAt"])
    }
}

// swiftlint:enable force_unwrapping
