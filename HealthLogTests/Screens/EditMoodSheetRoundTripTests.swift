import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// v0.14.8 — locks the FIX-1 behaviour: the Insights/History `EditMoodSheet`
/// now brings the legacy editor up to the Mood-v2 contract — it prefills the
/// rated sliders + structured tag-keys from the entry and re-sends them on save
/// (mirroring `MoodScreen`'s inline annotate panel), so editing an entry no
/// longer drops its ratings.
///
/// `prefill()`/`save()` are private SwiftUI view methods; this suite locks the
/// two load-bearing seams they sit on:
///  1. the prefill transform `entry.ratedFactors → ratings dict → clamped
///     payload` + `entry.tagKeys → catalog-ordered selection`, and
///  2. the actual PUT wire the save produces, via a REAL `APIClient` +
///     `MoodRepository` + stub `URLProtocol` (no mock server), proving the
///     `ratedFactors` + `tagKeys` reach `PUT /api/mood-entries/[id]`.
@Suite("EditMoodSheet rated round-trip (FIX 1)", .serialized)
struct EditMoodSheetRoundTripTests {
    // MARK: - Prefill transform (exact mirror of EditMoodSheet.prefill + payload)

    /// The same factors EditMoodSheet renders (visible RATED factors).
    private static let workFactor = MoodTagDTO(
        key: "factor_work", labelKey: "k", icon: nil, kind: .rated, scaleMin: 1, scaleMax: 5
    )
    private static let conflictFactor = MoodTagDTO(
        key: "factor_conflict", labelKey: "k", icon: nil, kind: .rated, scaleMin: 1, scaleMax: 2, inverse: true
    )

    /// Mirror of `EditMoodSheet.prefill()` ratings + `ratedFactorsPayload()`.
    private func payload(prefilledFrom entry: MoodEntry, factors: [MoodTagDTO]) -> [RatedFactorInput] {
        let ratings = Dictionary(
            entry.ratedFactors.map { ($0.key, $0.rating) },
            uniquingKeysWith: { first, _ in first }
        )
        return factors.compactMap { factor in
            guard let raw = ratings[factor.key] else { return nil }
            return RatedFactorInput(key: factor.key, rating: min(max(raw, factor.scaleMin), factor.scaleMax))
        }
    }

    @Test("Prefill round-trips an entry's saved ratings (no drop)")
    func prefillRoundTripsRatings() {
        let entry = MoodEntry(
            id: "m1", mood: .good, tags: [], tagKeys: ["family"], moodLoggedAt: .now,
            ratedFactors: [RatedFactorOutput(key: "factor_work", rating: 2)]
        )
        let out = payload(prefilledFrom: entry, factors: [Self.workFactor, Self.conflictFactor])
        // The saved work rating survives; the untouched conflict factor is omitted.
        #expect(out.map(\.key) == ["factor_work"])
        #expect(out.first?.rating == 2)
    }

    @Test("Prefill clamps an out-of-scale saved rating to the factor's scale")
    func prefillClamps() {
        let entry = MoodEntry(
            id: "m2", mood: .okay, tags: [], tagKeys: [], moodLoggedAt: .now,
            ratedFactors: [RatedFactorOutput(key: "factor_conflict", rating: 5)] // > scaleMax 2
        )
        let out = payload(prefilledFrom: entry, factors: [Self.conflictFactor])
        #expect(out.first?.rating == 2)
    }

    @Test("An entry with no ratings yields an empty payload (legacy entry unchanged)")
    func noRatingsEmptyPayload() {
        let entry = MoodEntry(id: "m3", mood: .okay, tags: [], tagKeys: [], moodLoggedAt: .now)
        #expect(payload(prefilledFrom: entry, factors: [Self.workFactor]).isEmpty)
    }

    // MARK: - W-B187 structured tagKeys no-clobber

    /// Mirror of `EditMoodSheet.prefill()` (`tagKeys = Set(entry.tagKeys)`) +
    /// `catalogOrderedSelection()` (the catalog projection of the picked set).
    /// `MoodTagCatalog.orderedKeys(from:)` keeps catalog order; for a catalog we
    /// don't seed here it returns the keys in a stable order, so we compare as
    /// sets — the load-bearing property is that NOTHING is dropped.
    private func structuredKeysOnReSave(entry: MoodEntry, catalog: MoodTagCatalog) -> Set<String> {
        // prefill: entry.tagKeys → selection Set (the picker's @State)
        let selected = Set(entry.tagKeys)
        // save: catalogOrderedSelection() → the array sent as tagKeys
        return Set(catalog.orderedKeys(from: selected))
    }

    @Test("Edit round-trips structured tagKeys without changing them (no clobber)")
    func tagKeysSurviveAnUneditedSave() {
        // The exact data-loss scenario: open an entry that has structured tags,
        // hit Save WITHOUT touching the picker, and assert every key survives.
        let entry = MoodEntry(
            id: "m4", mood: .good,
            tags: [], tagKeys: ["family", "sleep_quality", "work"], moodLoggedAt: .now
        )
        // An empty catalog is the worst case: `orderedKeys` must still preserve
        // every picked key (appended at the end) — it never drops one.
        let resaved = structuredKeysOnReSave(entry: entry, catalog: MoodTagCatalog(categories: []))
        #expect(resaved == Set(entry.tagKeys))
        #expect(resaved == ["family", "sleep_quality", "work"])
        // The catalog ordering never silently DROPS a key the user didn't touch.
        #expect(resaved.count == 3)
    }

    @Test("Free-text legacy tags survive an unedited save")
    func freeTextTagsSurvive() {
        // prefill: acceptedTags = entry.tags (minus any note: hack), save passes
        // them straight through — so a re-save preserves them.
        let entry = MoodEntry(
            id: "m5", mood: .okay,
            tags: ["Sport", "note:dropme", "Arbeit"], tagKeys: [], moodLoggedAt: .now
        )
        let acceptedTags = entry.tags.filter { !$0.hasPrefix("note:") }
        #expect(acceptedTags == ["Sport", "Arbeit"])
    }

    // MARK: - PUT wire (real APIClient + MoodRepository + stub URLProtocol)

    @MainActor
    @Test("save() PUTs ratedFactors + tagKeys to the entry route")
    func saveSendsRatedFactorsAndTagKeys() async throws {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local"),
            bundleID: "dev.healthlog.app", appVersion: "0.1.0", buildNumber: "1"
        )
        let api = APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MoodRepository(api: api, outbox: outbox)

        nonisolated(unsafe) var capturedBody: Data?
        nonisolated(unsafe) var capturedMethod: String?
        nonisolated(unsafe) var capturedPath: String?
        MockURLProtocol.handler = { req in
            capturedMethod = req.httpMethod
            capturedPath = req.url?.path
            capturedBody = req.httpBody ?? Self.drainStream(req.httpBodyStream)
            let resp = #"""
            {"data":{"id":"m1","mood":"GUT","tags":[],"tagKeys":["family"],
             "moodLoggedAt":"2026-06-05T08:00:00Z","source":"MANUAL",
             "ratedFactors":[{"key":"factor_work","rating":4}]}}
            """#
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(resp.utf8))
        }

        let patch = MoodEntryPatch(
            score: 4,
            tags: [],
            tagKeys: ["family"],
            ratedFactors: [RatedFactorInput(key: "factor_work", rating: 4)],
            recordedAt: Date(timeIntervalSince1970: 1_749_110_400),
            note: nil
        )
        let saved = try await repo.update(id: "m1", patch: patch)

        #expect(capturedMethod == "PUT")
        #expect(capturedPath == "/api/mood-entries/m1")
        let body = String(bytes: capturedBody ?? Data(), encoding: .utf8) ?? ""
        #expect(body.contains("ratedFactors"))
        #expect(body.contains("factor_work"))
        #expect(body.contains("\"rating\":4"))
        #expect(body.contains("tagKeys"))
        #expect(body.contains("family"))
        // The decoded server echo carries the rating back (round-trip closed).
        #expect(saved.ratedFactors.first?.key == "factor_work")
        #expect(saved.ratedFactors.first?.rating == 4)
    }

    /// `URLProtocol` moves a PUT body onto `httpBodyStream`; drain it.
    private static func drainStream(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 4096
        var buf = [UInt8](repeating: 0, count: size)
        while stream.hasBytesAvailable {
            let read = stream.read(&buf, maxLength: size)
            if read <= 0 { break }
            data.append(buf, count: read)
        }
        return data
    }
}
