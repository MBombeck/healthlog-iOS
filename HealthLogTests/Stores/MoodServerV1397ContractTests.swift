import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// #115 R3 — server v1.39.7 (unreleased at the time of writing; shapes from the
/// maintainer's 2026-10-01 08:45 note on #115):
///
/// 1. `GET /api/dashboard/summary` `metrics[kind=mood].updatedAt` moves from
///    `YYYY-MM-DDT00:00:00.000Z` to the start of the entry's day in the account
///    zone (Berlin `…T22:00:00.000Z` the evening before, Los Angeles
///    `…T07:00:00.000Z`). Same field, same type. The app decodes it as an
///    optional instant and passes it on without deriving a day from it.
/// 2. Mood writes gain `droppedTagKeys` / `droppedFactorKeys` when the server
///    did not store a key (unknown or archived). Before, those tags vanished
///    without a word; now the store reports them and the editors say so.
@Suite("R3 — mood contract of server v1.39.7", .mockURLSession)
@MainActor
struct MoodServerV1397ContractTests {
    // MARK: - Dashboard mood day

    private static func summary(moodUpdatedAt: String) -> Data {
        Data("""
        {
            "greeting": { "salutation": "Hi", "date": "2026-07-03T08:00:00.000Z" },
            "compliance": { "scheduledToday": 0, "takenToday": 0 },
            "highlightInsight": null,
            "metrics": [
                { "id": "mood1", "kind": "mood", "title": "Stimmung", "latestValue": 4, "unit": "",
                  "trend": "flat", "sparkline": [4], "updatedAt": "\(moodUpdatedAt)",
                  "lastSeenAt": "\(moodUpdatedAt)" }
            ],
            "lastUpdated": null
        }
        """.utf8)
    }

    @Test("The mood tile keeps the exact instant the server sends, in every zone shape", arguments: [
        "2026-07-02T22:00:00.000Z", // Berlin: start of 3 July
        "2026-07-03T07:00:00.000Z", // Los Angeles: start of 3 July
        "2026-07-03T00:00:00.000Z" // v1.39.6 and older
    ])
    func moodUpdatedAtInstant(raw: String) throws {
        let summary = try JSONDecoder.hlDefault.decode(DashboardSummary.self, from: Self.summary(moodUpdatedAt: raw))
        let mood = try #require(summary.metrics.first { $0.kind == .mood })
        let expected = try #require(ISO8601DateFormatter.fractional.date(from: raw))
        // Passed through verbatim — no re-anchoring to UTC midnight or a device day.
        #expect(mood.updatedAt == expected)
    }

    // MARK: - Dropped keys on mood writes

    @Test("A mood write response decodes droppedTagKeys / droppedFactorKeys")
    func decodesDroppedKeys() throws {
        let entry = try JSONDecoder.hlDefault.decode(MoodEntry.self, from: Data(#"""
        { "id": "m1", "mood": "GUT", "tags": [], "tagKeys": ["happy"],
          "moodLoggedAt": "2026-07-03T09:00:00.000Z", "source": "MANUAL",
          "droppedTagKeys": ["old_archived"], "droppedFactorKeys": ["gone_factor"] }
        """#.utf8))
        #expect(entry.droppedTagKeys == ["old_archived"])
        #expect(entry.droppedFactorKeys == ["gone_factor"])
        #expect(entry.droppedKeys == ["old_archived", "gone_factor"])
        #expect(entry.tagKeys == ["happy"])
    }

    @Test("Absent, null or malformed dropped keys mean 'everything arrived'")
    func droppedKeysTolerant() throws {
        for extra in ["", #","droppedTagKeys":null"#, #","droppedTagKeys":"x","droppedFactorKeys":[1]"#] {
            let json = #"{"id":"m1","mood":"OKAY","tags":[],"moodLoggedAt":"2026-07-03T09:00:00.000Z""#
                + extra + "}"
            let entry = try JSONDecoder.hlDefault.decode(MoodEntry.self, from: Data(json.utf8))
            #expect(entry.droppedKeys.isEmpty, "\(extra)")
        }
    }

    @Test("A request body never carries dropped keys (create path encodes the entry)")
    func encodeOmitsEmptyDroppedKeys() throws {
        let entry = MoodEntry(id: "local-1", recordedAt: .now, score: 4, tagKeys: ["happy"])
        let json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder.hlDefault.encode(entry)) as? [String: Any])
        #expect(json["droppedTagKeys"] == nil)
        #expect(json["droppedFactorKeys"] == nil)
    }

    private func makeStore() throws -> MoodStore {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local"),
            bundleID: "dev.healthlog.app",
            appVersion: "1.1.0",
            buildNumber: "286"
        )
        let api = APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
        return try MoodStore(repo: MoodRepository(api: api, outbox: OutboxQueue(inMemory: true)))
    }

    private static func installPut(answer: String) {
        MockURLProtocol.install { req in
            let status = req.httpMethod == "PUT" ? 200 : 404
            let body = req.httpMethod == "PUT" ? "{\"data\":\(answer),\"error\":null}" : "{}"
            return (HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
    }

    @Test("MoodStore.update reports the keys the server dropped, and clears them on the next clean save")
    func storeReportsDroppedKeys() async throws {
        let store = try makeStore()
        let entry = MoodEntry(id: "m1", recordedAt: Date(timeIntervalSince1970: 1_783_000_000), score: 4)
        store.replaceEntriesForTesting([entry])

        Self.installPut(answer: #"""
        {"id":"m1","mood":"GUT","tags":[],"tagKeys":["happy"],"moodLoggedAt":"2026-07-03T09:00:00.000Z",
         "droppedTagKeys":["old_archived"]}
        """#)
        let ok = await store.update(entry, score: 4, tags: [], tagKeys: ["happy", "old_archived"], recordedAt: entry.recordedAt)
        #expect(ok)
        #expect(store.lastWriteDroppedKeys == ["old_archived"])

        Self.installPut(answer: #"""
        {"id":"m1","mood":"GUT","tags":[],"tagKeys":["happy"],"moodLoggedAt":"2026-07-03T09:00:00.000Z"}
        """#)
        let again = await store.update(entry, score: 4, tags: [], tagKeys: ["happy"], recordedAt: entry.recordedAt)
        #expect(again)
        #expect(store.lastWriteDroppedKeys.isEmpty)
    }

    @Test("The notice exists in English and German")
    func copyBothLanguages() throws {
        for (language, title) in [("en", "Some tags weren't saved"), ("de", "Einige Tags wurden nicht gespeichert")] {
            let path = try #require(Bundle.main.path(forResource: language, ofType: "lproj"))
            let bundle = try #require(Bundle(path: path))
            #expect(bundle.localizedString(forKey: "mood.droppedKeys.title", value: "MISSING", table: nil) == title)
            let message = bundle.localizedString(forKey: "mood.droppedKeys.message", value: "MISSING", table: nil)
            #expect(message != "MISSING" && !message.isEmpty, "\(language)")
        }
    }
}

// swiftlint:enable force_unwrapping
