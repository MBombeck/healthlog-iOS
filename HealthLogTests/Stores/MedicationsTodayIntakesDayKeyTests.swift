import Foundation
@testable import HealthLog
import SwiftData
import Testing

// swiftlint:disable force_unwrapping

/// **v0.14.1 INV-med-cadence-phantom (BUG 2) — day-anchored today-intakes key.**
///
/// The `.medicationsTodayIntakes` cache key used to be static + non-day-anchored
/// with a flat 30s TTL. An optimistic `.taken` snapshot writeThrough'd to disk
/// replayed via SWR's `.cached` arm on the next launch and rendered a PHANTOM
/// "taken today" the server no longer agreed with (and DISABLED the Genommen
/// button → masked a real pending dose). The key now carries a profile-tz
/// `yyyy-MM-dd` day discriminator so a NEW calendar day is a STRUCTURAL cache
/// miss; a prior-day `.taken` snapshot can never carry across midnight.
@Suite("MedicationsStore — today-intakes day-anchored cache key", .serialized)
struct MedicationsTodayIntakesDayKeyTests {
    private final class StubReach: ReachabilityProviding, @unchecked Sendable {
        let online: Bool
        init(online: Bool) {
            self.online = online
        }

        var isOnlineStream: AsyncStream<Bool> {
            get async { AsyncStream { c in c.yield(online)
                c.finish()
            } }
        }

        func isCurrentlyOnline() async -> Bool {
            online
        }
    }

    // MARK: - Cache-key day discriminator

    @Test("today-intakes cache key differs across a day boundary")
    func keyDiffersAcrossDays() throws {
        let tz = try #require(TimeZone(identifier: "Europe/Berlin"))
        // Two instants 24h apart that fall on different Berlin days.
        let dayA = Date(timeIntervalSince1970: 1_733_400_000) // 2024-12-05 ~12:00Z
        let dayB = dayA.addingTimeInterval(24 * 60 * 60)

        let keyA = CacheKey.medicationsTodayIntakes(day: MedicationDayKey.string(for: dayA, timeZone: tz))
        let keyB = CacheKey.medicationsTodayIntakes(day: MedicationDayKey.string(for: dayB, timeZone: tz))

        #expect(keyA != keyB, "a new calendar day must produce a different cache key")
        #expect(keyA.persistentHash != keyB.persistentHash, "the persistent hash must differ across days")
        #expect(keyA.canonicalString.hasPrefix("medicationsTodayIntakes:"))
    }

    @Test("today-intakes key is stable within the same day")
    func keyStableWithinDay() throws {
        let tz = try #require(TimeZone(identifier: "Europe/Berlin"))
        let morning = Date(timeIntervalSince1970: 1_733_400_000)
        let evening = morning.addingTimeInterval(6 * 60 * 60)
        let a = CacheKey.medicationsTodayIntakes(day: MedicationDayKey.string(for: morning, timeZone: tz))
        let b = CacheKey.medicationsTodayIntakes(day: MedicationDayKey.string(for: evening, timeZone: tz))
        #expect(a == b, "two instants on the same day must share one key")
    }

    // MARK: - Phantom-taken does not survive the day boundary

    @Test("A stale prior-day .taken snapshot does NOT render as taken today after revalidate")
    @MainActor
    func priorDayTakenSnapshotDoesNotPhantom() async throws {
        let cache = try SWRCache(modelContainer: SWRCache.makeInMemory())
        let coordinator = SWRCoordinator(cache: cache, reachability: StubReach(online: true))
        let tz = try #require(TimeZone(identifier: "Europe/Berlin"))

        // Seed a stale `.taken` snapshot under YESTERDAY's day key — exactly the
        // phantom-producing snapshot the old static key would have replayed.
        let yesterday = try #require(Calendar.current.date(byAdding: .day, value: -1, to: .now))
        let yesterdayKey = CacheKey.medicationsTodayIntakes(
            day: MedicationDayKey.string(for: yesterday, timeZone: tz)
        )
        let phantomTaken = MedicationIntake(
            id: "intake-phantom",
            medicationId: "med-1",
            scheduledAt: yesterday,
            takenAt: yesterday,
            status: .taken
        )
        try await cache.write(yesterdayKey, payload: JSONEncoder.hlDefault.encode([phantomTaken]))

        // Server (authoritative) says today's dose is PENDING — nothing taken.
        let api = makeAPIClient()
        let outbox = try OutboxQueue(inMemory: true)
        MockURLProtocol.handler = { req in
            let path = req.url?.path ?? ""
            let method = req.httpMethod ?? "GET"
            let query = req.url?.query ?? ""
            if path == "/api/medications", method == "GET" {
                return (Self.ok(req), Data(#"{"data":[]}"#.utf8))
            }
            if path == "/api/medications/intake", method == "GET", query.contains("scope=today") {
                let body = #"{"data":[{"id":"intake-today","medicationId":"med-1","scheduledAt":"2026-06-06T08:00:00Z","takenAt":null,"status":"pending","snoozedUntil":null}]}"#
                return (Self.ok(req), Data(body.utf8))
            }
            if path == "/api/medications/intake", method == "GET", query.contains("scope=compliance") {
                return (Self.ok(req), Data(#"{"data":[]}"#.utf8))
            }
            return (
                HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!,
                Data()
            )
        }
        let repo = MedicationsRepository(api: api, outbox: outbox)
        let store = MedicationsStore(repo: repo, swr: coordinator)
        // Pin the store's day-anchoring zone so its `todayIntakesKey` resolves to
        // TODAY's key (not yesterday's) — the prior-day snapshot must not match.
        store.profileTimeZoneProvider = { tz }

        await store.load()

        // The store must reflect the SERVER's pending dose, NOT the stale
        // prior-day `.taken` snapshot. No phantom-taken, no masked dose.
        #expect(store.todayIntakes.count == 1)
        #expect(store.todayIntakes.first?.id == "intake-today")
        #expect(store.todayIntakes.first?.status == .pending, "prior-day .taken must not carry into today")
        #expect(
            !store.todayIntakes.contains { $0.status == .taken },
            "no .taken row may survive the day boundary"
        )
    }

    // MARK: - Helpers

    @MainActor
    private func makeAPIClient() -> APIClient {
        let keychain = InMemoryKeychain()
        try? keychain.setString("token", forKey: KeychainKey.authToken)
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.5.0",
            buildNumber: "1"
        )
        return APIClient(
            environment: env,
            keychain: keychain,
            sessionConfiguration: .mock()
        )
    }

    private static func ok(_ request: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
    }
}

// swiftlint:enable force_unwrapping
