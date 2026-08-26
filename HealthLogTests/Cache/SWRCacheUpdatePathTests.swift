import Foundation
@testable import HealthLog
import SwiftData
import Testing

/// Bundle anchor for the committed b267 store fixture.
final class B267FixtureAnchor {}

/// **Phase 21 (21-02) — the update path, from a real pre-change artifact.**
///
/// Users update; they do not reinstall. So the question this suite answers is
/// not "does the cache round-trip" — `SWRCacheTests` already answers that —
/// but "does a store that the **shipped b267 code wrote** still read correctly
/// under the changed reader".
///
/// **Provenance of the fixture, because that is the entire point.**
/// `HealthLogTests/Fixtures/b267-cache/cache.sqlite` was produced by checking
/// out `v0.19.0-b267` into a detached worktree, building that tree's own
/// `HealthLogCore` SPM target, and calling **b267's** `SWRCache.makePersistent()`
/// and **b267's** `SWRCache.write` from a throwaway executable. Nothing in this
/// repository's working tree wrote a byte of it. The WAL was checkpointed into
/// the main file afterwards (`PRAGMA wal_checkpoint(TRUNCATE)`) so the fixture
/// is one committable file — that consolidates SQLite bookkeeping and leaves
/// every row's `keyHash`, `payloadData`, `updatedAt` and `schemaVersion`
/// untouched, which is what a cleanly-closed app leaves behind anyway.
///
/// **Why it is not a store this code created.** Plan 13-05 shipped a
/// server-address wipe because every test pre-seeded the sentinel whose absence
/// was the trigger — a green suite describing a world the device is not in. The
/// direct application here is that a fixture written by the new writer would
/// pass no matter what the change did to the format, and would prove exactly
/// nothing about an updating user.
///
/// **What it would have caught.** Any change to `CachedSnapshot`'s stored
/// properties or `CacheSchemaV1.versionIdentifier` (SwiftData would refuse the
/// store or migrate it), any bump of `currentSchemaVersion` (every row reads as
/// a cache-miss and is dropped), any drift in `CacheKey.persistentHash` (the
/// rows are still there and nothing can find them), and any change to
/// `JSONDecoder.hlDefault`'s date strategy — the fixture carries a `YYYY-MM-DD`
/// day-key **and** a fractional ISO8601 instant precisely so both branches of
/// `iso8601WithFractionalOrDayKey` are load-bearing here.
///
/// **Status honestly stated.** This suite is GREEN before 21-02's change and
/// green after. That is its role: it is fail-closed protection, not a RED, and
/// laundering it into one would be a lie about what was demanded of the fix.
@Suite("SWRCache — a b267-written store still reads after the change")
struct SWRCacheUpdatePathTests {
    // MARK: - The payloads b267 wrote

    struct FixtureProfile: Codable, Equatable {
        let id: String
        let displayName: String
        let locale: String
    }

    struct FixtureMedication: Codable, Equatable {
        let id: String
        let name: String
        let dose: String
    }

    struct FixtureSummary: Codable, Equatable {
        let day: String
        let score: Int
        let entries: Int
    }

    /// `date` is a `YYYY-MM-DD` day-key on the wire — the branch of
    /// `JSONDecoder.hlDefault`'s custom strategy that `DateFormatter.hlDayKey`
    /// serves.
    struct FixtureComplianceDay: Codable, Equatable {
        let date: Date
        let taken: Int
        let planned: Int
    }

    struct FixtureAvailability: Codable, Equatable {
        let kinds: [String]
    }

    /// `updated` is a fractional-seconds ISO8601 instant — the other branch.
    struct FixtureScore: Codable, Equatable {
        let value: Int
        let trend: String
        let updated: Date
    }

    /// The instant b267's writer stamped every row with.
    static let writtenAt = Date(timeIntervalSince1970: 1_787_000_000)

    // MARK: - Opening the artifact

    /// Copies the read-only bundle fixture somewhere writable and opens it with
    /// **exactly** the production `ModelConfiguration` — same store name, same
    /// schema, no migration plan. A different name or schema here would be a
    /// test that opens some other store and says nothing about the real one.
    static func openFixtureStore() throws -> (cache: SWRCache, directory: URL) {
        let bundle = Bundle(for: B267FixtureAnchor.self)
        let source = try #require(
            bundle.url(forResource: "cache", withExtension: "sqlite"),
            "the b267 store fixture is missing from the test bundle"
        )
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        // Sweep what earlier runs left behind, at OPEN rather than at close.
        // The `ModelContainer` outlives the test's scope, and deleting a store
        // out from under a live container is what filled the log with SQLite
        // `disk I/O error` lines — noise that looks exactly like a real defect.
        let siblings = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for stale in siblings where stale.lastPathComponent.hasPrefix("b267-update-path-") {
            try? FileManager.default.removeItem(at: stale)
        }
        let directory = root.appendingPathComponent("b267-update-path-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("cache.sqlite")
        try FileManager.default.copyItem(at: source, to: destination)

        let schema = Schema(versionedSchema: CacheSchemaV1.self)
        let config = ModelConfiguration(
            "HealthLogCache",
            schema: schema,
            url: destination,
            allowsSave: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, migrationPlan: nil, configurations: [config])
        return (SWRCache(modelContainer: container), directory)
    }

    /// Reads one key through the **production** path — `SWRCoordinator.observe`
    /// with reachability offline, which is the ladder arm an updating user's
    /// first paint actually takes on a warm cache. Not through a test-only
    /// convenience: the thing under test is what the app does.
    static func firstPaint<T: Codable & Sendable>(
        _ key: CacheKey,
        as _: T.Type,
        from cache: SWRCache,
        fallback: @escaping @Sendable () -> T
    ) async -> SWRState<T>? {
        let coordinator = SWRCoordinator(cache: cache, reachability: OfflineReachability())
        let stream = await coordinator.observe(key, decoding: T.self) { fallback() }
        for await state in stream {
            return state
        }
        return nil
    }

    // MARK: - Cases

    @Test("Jeder von b267 geschriebene Key liest unter dem neuen Reader unverändert zurück")
    func everySeededKeyReadsBackEqual() async throws {
        let store = try Self.openFixtureStore()

        let profile = await Self.firstPaint(.userProfile, as: FixtureProfile.self, from: store.cache) {
            FixtureProfile(id: "miss", displayName: "miss", locale: "miss")
        }
        guard case let .cached(value, _)? = profile else {
            Issue.record("userProfile did not read back from the b267 store: \(String(describing: profile))")
            return
        }
        #expect(value == FixtureProfile(id: "u-1", displayName: "Fixture", locale: "de_DE"))

        let meds = await Self.firstPaint(.medicationsList, as: [FixtureMedication].self, from: store.cache) { [] }
        guard case let .cached(list, _)? = meds else {
            Issue.record("medicationsList did not read back from the b267 store: \(String(describing: meds))")
            return
        }
        #expect(list == [
            FixtureMedication(id: "m-1", name: "Substanz A", dose: "5 mg"),
            FixtureMedication(id: "m-2", name: "Substanz B", dose: "10 mg")
        ])

        let summary = await Self.firstPaint(
            .dashboardSummary(day: "2026-08-24"),
            as: FixtureSummary.self,
            from: store.cache
        ) { FixtureSummary(day: "miss", score: -1, entries: -1) }
        guard case let .cached(dashboard, _)? = summary else {
            Issue.record("dashboardSummary did not read back: \(String(describing: summary))")
            return
        }
        #expect(dashboard == FixtureSummary(day: "2026-08-24", score: 71, entries: 3))

        let availability = await Self.firstPaint(
            .measurementAvailability,
            as: FixtureAvailability.self,
            from: store.cache
        ) { FixtureAvailability(kinds: []) }
        guard case let .cached(kinds, _)? = availability else {
            Issue.record("measurementAvailability did not read back: \(String(describing: availability))")
            return
        }
        #expect(kinds == FixtureAvailability(kinds: ["weight", "pulse", "mood"]))
    }

    @Test("Beide Date-Zweige des geteilten Decoders überleben den Update-Pfad")
    func bothDateStrategyBranchesSurvive() async throws {
        let store = try Self.openFixtureStore()

        // Day-key branch: "2026-08-23" is midnight UTC, per the server
        // convention `DateFormatter.hlDayKey` encodes.
        let compliance = await Self.firstPaint(
            .medicationsCompliance(days: 30),
            as: [FixtureComplianceDay].self,
            from: store.cache
        ) { [] }
        guard case let .cached(days, _)? = compliance else {
            Issue.record("medicationsCompliance did not read back: \(String(describing: compliance))")
            return
        }
        #expect(days.count == 2)
        let dayKeyFormatter = DateFormatter.hlDayKey
        #expect(days.first.map { dayKeyFormatter.string(from: $0.date) } == "2026-08-23")
        #expect(days.last.map { dayKeyFormatter.string(from: $0.date) } == "2026-08-24")
        #expect(days.first?.taken == 2)
        #expect(days.last?.planned == 2)

        // Fractional-ISO8601 branch.
        let score = await Self.firstPaint(.healthScore, as: FixtureScore.self, from: store.cache) {
            FixtureScore(value: -1, trend: "miss", updated: .distantPast)
        }
        guard case let .cached(health, _)? = score else {
            Issue.record("healthScore did not read back: \(String(describing: score))")
            return
        }
        #expect(health.value == 71)
        #expect(health.trend == "steady")
        #expect(
            health.updated == ISO8601DateFormatter.fractional.date(from: "2026-08-24T01:00:00.000Z"),
            "the fractional-seconds ISO8601 branch decoded a different instant than b267 encoded"
        )
    }

    @Test("Der Zeitstempel, den b267 schrieb, überquert die Actor-Grenze unverändert")
    func theWriteTimestampSurvivesTheBoundary() async throws {
        let store = try Self.openFixtureStore()

        // 21-02 moves the payload bytes and the metadata across the actor
        // boundary as separate things. If the `updatedAt` that travels with
        // them drifted, every staleness decision on an updating device would
        // drift with it — the cache would look permanently fresh or
        // permanently stale and nothing would say which.
        let cached: Cached<FixtureProfile>? = await store.cache.read(.userProfile, as: FixtureProfile.self)
        let row = try #require(cached, "the b267 row is not readable at all")
        #expect(
            abs(row.updatedAt.timeIntervalSince(Self.writtenAt)) < 0.001,
            "b267 stamped \(Self.writtenAt) and the reader returned \(row.updatedAt)"
        )
        #expect(row.value.id == "u-1")
    }

    @Test("Ein Key, den b267 nie schrieb, ist ein Cache-Miss und kein Fehler")
    func anUnseededKeyIsAMissNotAFailure() async throws {
        let store = try Self.openFixtureStore()

        // Control probe FIRST. A store that failed to open emits `.empty` for
        // every key, including the seeded ones — so without this the assertion
        // below would pass most loudly exactly when the fixture was broken.
        let control = await Self.firstPaint(.userProfile, as: FixtureProfile.self, from: store.cache) {
            FixtureProfile(id: "miss", displayName: "miss", locale: "miss")
        }
        guard case .cached? = control else {
            Issue.record("control probe failed — the b267 store did not open, so a `.empty` below proves nothing")
            return
        }

        let missing = await Self.firstPaint(.labsResults, as: FixtureAvailability.self, from: store.cache) {
            FixtureAvailability(kinds: [])
        }
        guard case .empty? = missing else {
            Issue.record("an unseeded key must emit .empty, got \(String(describing: missing))")
            return
        }
    }
}
