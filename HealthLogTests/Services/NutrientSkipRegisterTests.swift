import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// INT-A (#115 / 0.3) — nutrient refusals live in the ONE skip register.
///
/// * The update path: rows an earlier build kept in the UserDefaults list
///   (`hl.healthkit.nutrientRefusals.<token>`) move into the register on the
///   next sweep, and the old key is gone afterwards.
/// * A refusal is passed only once it is remembered: a register write that
///   does not verify keeps `lastSweepEnd` where it was.
///
/// Real `APIClient` over `MockURLProtocol`.
@Suite("Nutrient refusals → skip register (INT-A)", .serialized, .mockURLSession)
struct NutrientSkipRegisterTests {
    private static let fixedNow = Date(timeIntervalSince1970: 1_783_000_000)
    private static let lastSweepKey = NutrientDailySyncCoordinator.lastSweepEndKeyPrefix
        + HealthKitBackfillWindowStore.partitionToken(for: "user-123")

    private static let insertedBody = #"""
    {"data":{"processed":1,"inserted":1,"updated":0,"skipped":[],"entries":[{"index":0,"status":"inserted"}]},"error":null}
    """#

    private static let outOfRangeBody = #"""
    {"data":{"processed":1,"inserted":0,"updated":0,
    "skipped":[{"index":0,"reason":"value_out_of_range"}],
    "entries":[{"index":0,"status":"skipped","reason":"value_out_of_range"}]},"error":null}
    """#

    private func respond(_ body: String) {
        MockURLProtocol.install { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
    }

    private func isolatedDefaults() -> @Sendable () -> UserDefaults {
        let suite = "nutrient.register.tests.\(UUID().uuidString)"
        UserDefaults(suiteName: suite)!.removePersistentDomain(forName: suite)
        return { UserDefaults(suiteName: suite)! }
    }

    private func makeCoordinator(
        nutrient identifier: String,
        amount: Double,
        defaults: @escaping @Sendable () -> UserDefaults
    ) -> NutrientDailySyncCoordinator {
        let keychain = InMemoryKeychain()
        try? keychain.setString("bearer-abc", forKey: KeychainKey.authToken)
        try? keychain.setString("user-123", forKey: KeychainKey.userID)
        let api = APIClient(
            environment: AppEnvironment(
                baseURL: URL(string: "https://test.healthlog.local")!,
                bundleID: "dev.healthlog.app",
                appVersion: "1.0.4",
                buildNumber: "1"
            ),
            keychain: keychain,
            sessionConfiguration: .mock()
        )
        return NutrientDailySyncCoordinator(
            statisticsService: OneNutrientDay(identifier: identifier, amount: amount),
            api: api,
            keychain: keychain,
            isModuleEnabled: { true },
            calendar: .current,
            clock: { Self.fixedNow },
            defaultsProvider: defaults
        )
    }

    private static func register(lossy: Bool = false) -> HealthKitSkippedRowRegister {
        let file = RegisterFile()
        return HealthKitSkippedRowRegister(storage: HealthKitSkippedRowStorage(
            load: { file.read() },
            save: { data in if !lossy { file.write(data) } }
        ))
    }

    @Test("refusals from the earlier UserDefaults list move into the skip register once")
    func legacyNutrientRefusalsMigrate() async {
        respond(Self.insertedBody)
        let defaults = isolatedDefaults()
        let legacy = NutrientRefusalRegister(defaultsProvider: defaults, userID: "user-123")
        let iron = NutrientIntakeEntryDTO(day: "2026-06-01", nutrient: .iron, unit: "mg", amount: 480)
        legacy.record([NutrientRefusal(entry: iron, reason: "value_out_of_range")])
        let register = Self.register()

        await HealthKitSkippedRowRegister.$bound.withValue(register) {
            _ = await makeCoordinator(
                nutrient: "HKQuantityTypeIdentifierDietaryVitaminC",
                amount: 88,
                defaults: defaults
            ).sync()
        }

        let moved = await register.rows(ownerID: "user-123")
        #expect(moved.map(\.nutrient) == [iron])
        #expect(moved.first?.reason == "value_out_of_range")
        #expect(legacy.entries.isEmpty, "the old list is removed once its rows are in the register")
    }

    @Test("a refusal the register cannot keep holds the sweep")
    func unrecordedRefusalHoldsTheSweep() async {
        respond(Self.outOfRangeBody)
        let defaults = isolatedDefaults()

        await HealthKitSkippedRowRegister.$bound.withValue(Self.register(lossy: true)) {
            _ = await makeCoordinator(
                nutrient: "HKQuantityTypeIdentifierDietaryZinc",
                amount: 999_999,
                defaults: defaults
            ).sync()
        }

        #expect(defaults().object(forKey: Self.lastSweepKey) == nil, "the day is posted again next sweep")
    }
}

/// One nutrient, one day with data.
private struct OneNutrientDay: NutrientDailyRowsProviding {
    let identifier: String
    let amount: Double

    func dailyRows(
        forNutrientIdentifier identifier: String,
        wireUnit: String,
        from _: Date,
        to _: Date
    ) async throws -> [HealthKitDailyStatRow] {
        guard identifier == self.identifier else { return [] }
        return [HealthKitDailyStatRow(
            hkIdentifier: identifier,
            dayStart: Date(timeIntervalSince1970: 0),
            dayKey: "2026-07-06",
            value: amount,
            unit: wireUnit
        )]
    }
}

private final class RegisterFile: @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?

    func read() -> Data? {
        lock.withLock { data }
    }

    func write(_ value: Data) {
        lock.withLock { data = value }
    }
}

// swiftlint:enable force_unwrapping
