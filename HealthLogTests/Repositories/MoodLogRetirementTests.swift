import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// CU-14 — the moodLog bridge is retired; its provenance is not.
///
/// The server removed the integration in v1.32.33: the routes
/// `/api/integrations/moodlog/*` and `/api/settings/moodlog` are gone,
/// migration 0271 dropped the columns, and `moodLogGlobal` left the
/// global-services shape. iOS never called any of it, so nothing had to be
/// torn out — these tests pin the *other* half of that removal, the half that
/// is easy to delete by accident:
///
/// `MOODLOG` survives as a **mood-entry provenance value**. Rows the bridge
/// imported are the user's own history and keep their label; the server
/// deliberately goes on resolving it (`src/lib/validations/mood.ts:23-31`,
/// guarded by `src/__tests__/moodlog-removal-guard.test.ts`, which forbids
/// every moodLog surface but explicitly not this value). Nothing mints new
/// `MOODLOG` rows.
@Suite("moodLog retirement — provenance survives the bridge (CU-14)", .serialized)
struct MoodLogRetirementTests {
    private func makeAPI() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            cfAccessClientID: nil,
            cfAccessClientToken: nil,
            bundleID: "dev.healthlog.app",
            appVersion: "0.14.0",
            buildNumber: "1"
        )
        let keychain = InMemoryKeychain()
        try? keychain.setString("token", forKey: KeychainKey.authToken)
        return APIClient(environment: env, keychain: keychain, sessionConfiguration: .mock())
    }

    // MARK: - The value stays

    @Test("a historical row imported by the retired bridge keeps its provenance")
    func historicalMoodLogRowDecodes() throws {
        let json = Data(#"""
        {
          "id": "srv-mood-legacy-1", "mood": "GUT", "tags": [],
          "moodLoggedAt": "2025-11-02T19:30:00.000Z", "source": "MOODLOG", "note": null
        }
        """#.utf8)
        let entry = try JSONDecoder.hlDefault.decode(MoodEntry.self, from: json)
        #expect(entry.source == "MOODLOG", "The bridge is gone; the rows it wrote are still the user's history")
    }

    @Test("provenance is decoded as a plain String — an unknown value never breaks a row")
    func unknownProvenanceIsNotFatal() throws {
        // `MoodEntry.source` is `String?`, deliberately not `MoodEntrySource`.
        // A provenance value iOS has never heard of must cost nothing.
        let json = Data(#"""
        {
          "id": "srv-mood-future-1", "mood": "OKAY", "tags": [],
          "moodLoggedAt": "2026-07-30T08:00:00.000Z", "source": "SOME_FUTURE_BRIDGE", "note": null
        }
        """#.utf8)
        let entry = try JSONDecoder.hlDefault.decode(MoodEntry.self, from: json)
        #expect(entry.source == "SOME_FUTURE_BRIDGE")
    }

    @Test("the history filter still offers moodLog, and only the five server values")
    func filterVocabularyMatchesServer() {
        // Mirrors `moodSourceEnum` (`src/lib/validations/mood.ts:29-35`) verbatim.
        #expect(MoodEntrySource.allCases.map(\.rawValue) == ["MANUAL", "MOODLOG", "WEB", "TELEGRAM", "DAYLIO"])
        #expect(MoodEntrySource(rawValue: "MOODLOG") == .moodlog)
    }

    @Test("filtering by moodLog emits source=MOODLOG as a query parameter")
    func queryItemsCarryTheLegacySource() {
        let query = MoodHistoryQuery(source: .moodlog, limit: 25, offset: 0)
        let items = query.queryItems
        #expect(items.contains { $0.0 == "source" && $0.1 == "MOODLOG" })
    }

    @Test("history(query:) reaches the live route with the legacy source filter")
    func historyRequestCarriesTheLegacySource() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MoodRepository(api: api, outbox: outbox)

        let recorder = URLRecorder()
        MockURLProtocol.handler = { req in
            recorder.record(req.url)
            let body = #"""
            {"data":{"entries":[{"id":"srv-mood-legacy-1","mood":"GUT","tags":[],
            "moodLoggedAt":"2025-11-02T19:30:00.000Z","source":"MOODLOG","note":null}],
            "meta":{"total":1,"limit":25,"offset":0}}}
            """#
            return (
                HTTPURLResponse(
                    url: req.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(body.utf8)
            )
        }
        defer { MockURLProtocol.handler = nil }

        let response = try await repo.history(query: MoodHistoryQuery(source: .moodlog))

        let observed = try #require(recorder.url, "The repo must have reached the network")
        let items = URLComponents(url: observed, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.contains { $0.name == "source" && $0.value == "MOODLOG" })
        #expect(observed.path == "/api/mood-entries")
        #expect(response.entries.first?.source == "MOODLOG")
    }

    /// Minimal `Sendable` box so the handler closure can hand the observed URL
    /// back to the test body.
    private final class URLRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var observed: URL?

        func record(_ url: URL?) {
            lock.lock()
            defer { lock.unlock() }
            observed = url
        }

        var url: URL? {
            lock.lock()
            defer { lock.unlock() }
            return observed
        }
    }
}

/// CU-14 — an absent integration provider is a legal state.
///
/// The plan feared an `integrations[]` index break on
/// `GET /api/integrations/status`. That route is not consumed anywhere in the
/// app; the OAuth surfaces read the per-provider `GET /api/<provider>/status`
/// instead, so there is no array and no index to break. What these tests pin is
/// the property that actually matters: a status payload carrying nothing but
/// the required `connected` flag decodes, and every richer field staying absent
/// is silence rather than a special case.
@Suite("Provider status — absence is a legal state (CU-14)")
struct ProviderStatusAbsenceTests {
    @Test("a minimal status payload decodes with every optional absent")
    func minimalStatusDecodes() throws {
        let decoded = try JSONDecoder.hlDefault.decode(
            OAuthIntegrationStatus.self,
            from: Data(#"{ "connected": false }"#.utf8)
        )
        #expect(decoded.connected == false)
        #expect(decoded.configured == nil)
        #expect(decoded.state == nil)
        #expect(decoded.lastSync == nil, "No ledger, no invented timestamp")
        #expect(decoded.isParkedOrError == false, "An absent state is calm, not an error")
    }

    @Test("unknown server fields are ignored rather than fatal")
    func unknownFieldsTolerated() throws {
        let json = Data(#"""
        { "connected": true, "state": "ok", "somethingTheServerAddedLater": { "nested": 1 } }
        """#.utf8)
        let decoded = try JSONDecoder.hlDefault.decode(OAuthIntegrationStatus.self, from: json)
        #expect(decoded.connected == true)
        #expect(decoded.isParkedOrError == false)
    }

    @Test("a parked or errored ledger reads as needs-attention, an absent one does not")
    func parkedStateIsHonest() throws {
        let parked = try JSONDecoder.hlDefault.decode(
            OAuthIntegrationStatus.self,
            from: Data(#"{ "connected": true, "state": "parked" }"#.utf8)
        )
        #expect(parked.isParkedOrError == true)

        let unknownState = try JSONDecoder.hlDefault.decode(
            OAuthIntegrationStatus.self,
            from: Data(#"{ "connected": true, "state": null }"#.utf8)
        )
        #expect(unknownState.isParkedOrError == false)
    }

    @Test("Nightscout status tolerates the same minimal shape")
    func nightscoutMinimalDecodes() throws {
        let decoded = try JSONDecoder.hlDefault.decode(
            NightscoutStatus.self,
            from: Data(#"{ "connected": false }"#.utf8)
        )
        #expect(decoded.connected == false)
        #expect(decoded.configured == nil)
        #expect(decoded.isParkedOrError == false)
    }
}
