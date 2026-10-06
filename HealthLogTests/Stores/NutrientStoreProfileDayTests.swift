import Foundation
@testable import HealthLog
import Testing

/// **#115 B5 — the nutrient screen's "today" is the account's day.**
///
/// A water quick-add without a `day` is keyed by the server in the account zone
/// (`POST /api/nutrients/water`, `userDayKey(new Date(), user.timezone)` at
/// v1.39.0), and the HealthKit day totals are keyed in it too (Audit B-7). The
/// optimistic row the store paints while the write is in flight named the
/// DEVICE day, so for a phone in another zone the first sip of the day showed
/// up under a day the server never wrote.
@Suite("#115 B5 — NutrientStore today key in the profile zone")
@MainActor
struct NutrientStoreProfileDayTests {
    /// Every request fails retriably, so the write is queued and the optimistic
    /// row stays on screen — the state this test reads.
    private struct OfflineAPI: APIClientProtocol {
        func send<T: Decodable & Sendable>(_: APIRequest<T>) async throws -> T {
            throw HLError.network(.connectionLost)
        }

        func sendVoid(_: APIRequest<EmptyPayload>) async throws {
            throw HLError.network(.connectionLost)
        }

        func download(_: APIRequest<Data>) async throws -> (Data, HTTPURLResponse) {
            throw HLError.network(.connectionLost)
        }
    }

    @Test("a first water add is keyed on today in the account zone, not the device's")
    func firstWaterRowUsesProfileDay() async throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-06-19T11:00:00Z"))
        let deviceKey = ProfileDay.key(for: now, timeZone: .current)
        // Kiritimati (UTC+14) is already on 06-20; Pago Pago (UTC−11) is on
        // 06-19. Whichever the device is not on, so the fallback cannot pass.
        let kiritimati = try #require(TimeZone(identifier: "Pacific/Kiritimati"))
        let pagoPago = try #require(TimeZone(identifier: "Pacific/Pago_Pago"))
        let (profile, expected) = deviceKey == "2026-06-20"
            ? (pagoPago, "2026-06-19")
            : (kiritimati, "2026-06-20")

        let store = try NutrientStore(
            repository: NutrientReadRepository(api: OfflineAPI(), outbox: OutboxQueue(inMemory: true))
        )
        store.profileTimeZone = { profile }
        store.now = { now }

        await store.addWater(amountMl: 250)

        let water = try #require(store.rows.first { $0.nutrient == .water })
        #expect(water.latestDay == expected)
        #expect(water.latestAmount == 250)
        #expect(store.todayKey() == expected)
    }
}
