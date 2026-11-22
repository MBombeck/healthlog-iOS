import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// **A check-up whose target is blood ketones.**
///
/// The server lets a Vorsorge target `BLOOD_KETONES`. The app names that type on
/// the card and charts its readings in the detail, but never offers it in the
/// create sheet and cannot capture it, so the primary action stays mark-done.
/// Real `APIClient` + `MockURLProtocol` for the detail load, hence `.serialized`.
@Suite("Vorsorge ketone reminder", .serialized, .mockURLSession)
@MainActor
struct VorsorgeKetoneReminderTests {
    private static func row(type: String?) -> MeasurementReminderRow {
        MeasurementReminderRow(
            id: "k1",
            label: "Ketone vor dem Frühstück",
            measurementType: type,
            intervalDays: 7,
            rrule: nil,
            endsOn: nil,
            origin: .vorsorge,
            notifyHour: 8,
            location: nil,
            nextDueAt: nil,
            lastSatisfiedAt: nil,
            enabled: true
        )
    }

    private static func makeAPI() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "1.0.0",
            buildNumber: "1"
        )
        let keychain = InMemoryKeychain()
        try? keychain.setString("token", forKey: KeychainKey.authToken)
        return APIClient(environment: env, keychain: keychain, sessionConfiguration: .mock())
    }

    // MARK: - Type label

    @Test("BLOOD_KETONES resolves to the catalog name, not the fallback")
    func labelResolvesCatalogName() {
        let label = MeasurementReminderType.label(for: "BLOOD_KETONES", fallback: "Ketone messen")
        #expect(label != "Ketone messen")
        #expect(label != "reminder.type.bloodKetones")
        #expect(label == String(localized: "reminder.type.bloodKetones"))
    }

    @Test("the create-sheet catalog does not offer BLOOD_KETONES")
    func catalogLeavesKetonesOut() {
        #expect(!MeasurementReminderType.catalog.contains { $0.wire == "BLOOD_KETONES" })
        #expect(MeasurementReminderType.catalog.contains { $0.wire == "WEIGHT" })
    }

    @Test("an unknown type still falls back to the user's title")
    func unknownTypeKeepsFallback() {
        #expect(MeasurementReminderType.label(for: "SOME_FUTURE_TYPE", fallback: "Mein Titel") == "Mein Titel")
    }

    // MARK: - Card routing

    @Test("primary action stays mark-done, the detail charts the ketone history")
    func actionAndDetailArm() {
        let ketones = Self.row(type: "BLOOD_KETONES")
        #expect(VorsorgeCard.primaryAction(for: ketones) == .markDone)
        #expect(VorsorgeCard.detailArm(for: ketones) == .metric(.bloodKetones))
        #expect(VorsorgeNextDue.prefillKind(forServerType: "BLOOD_KETONES") == nil)
    }

    // MARK: - Detail load

    @Test("the detail loads ketone readings through the type-scoped list")
    func detailLoadsKetoneReadings() async throws {
        let api = Self.makeAPI()

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let body = "{\"data\":{\"measurements\":[" +
            "{\"id\":\"k2\",\"type\":\"BLOOD_KETONES\",\"value\":0.6,\"unit\":\"mmol/L\"," +
            "\"measuredAt\":\"\(formatter.string(from: now))\"}," +
            "{\"id\":\"k1\",\"type\":\"BLOOD_KETONES\",\"value\":0.4,\"unit\":\"mmol/L\"," +
            "\"measuredAt\":\"\(formatter.string(from: now.addingTimeInterval(-86400)))\"}]}}"
        let payload = Data(body.utf8)
        let requestedTypes = LockedTypes()
        MockURLProtocol.install { req in
            let items = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            requestedTypes.append(items.first { $0.name == "type" }?.value)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, payload)
        }

        let repo = try MeasurementsRepository(api: api, outbox: OutboxQueue(inMemory: true))
        let store = try MentalHealthStore(
            repository: MentalHealthRepository(api: api, outbox: OutboxQueue(inMemory: true))
        )
        let model = VorsorgeDetailModel(
            row: Self.row(type: "BLOOD_KETONES"),
            measurementsRepo: repo,
            mentalHealthStore: store
        )
        await model.load()

        #expect(requestedTypes.values.contains("BLOOD_KETONES"))
        #expect(model.points.map(\.value) == [0.4, 0.6])
        #expect(model.metricMeasurements.count == 2)
        #expect(model.metricMeasurements.allSatisfy { $0.kind == .bloodKetones })
        #expect(!model.isLoading)
    }
}

/// Collects the `type` query of every request the mock answered.
private final class LockedTypes: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String?] = []

    func append(_ value: String?) {
        lock.withLock { stored.append(value) }
    }

    var values: [String?] {
        lock.withLock { stored }
    }
}
