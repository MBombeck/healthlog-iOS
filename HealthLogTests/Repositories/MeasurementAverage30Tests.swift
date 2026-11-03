import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// **1.4 B4 — the "30 Tage Durchschnitt" card reads the server's mean.**
///
/// The metric page's 30-day card took its number from the comprehensive digest
/// and fell back to the latest reading. The digest is consent-gated, so for
/// many accounts the card showed today's value under a heading that promised a
/// 30-day mean (day strain and RMSSD in the B3 screenshots). The summaries
/// slice carries the same server `avg30` for every type and is not gated; these
/// tests pin that the repository reads it from there, per type, and passes
/// "no reading in 30 days" through as no average.
@Suite("1.4 B4: the metric page's 30-day average comes from the server", .serialized, .mockURLSession)
struct MeasurementAverage30Tests {
    private func makeRepository() throws -> MeasurementsRepository {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "1.4.0",
            buildNumber: "1"
        )
        let keychain = InMemoryKeychain()
        try? keychain.setString("token", forKey: KeychainKey.authToken)
        let api = APIClient(environment: env, keychain: keychain, sessionConfiguration: .mock())
        return try MeasurementsRepository(api: api, outbox: OutboxQueue(inMemory: true))
    }

    /// The slice as the server sends it: `latest` is today's value, `avg30` the
    /// mean of the last 30 days, `null` once a type stopped.
    private static let slice = """
    {"summaries":{
      "DAY_STRAIN":{"count":45,"latest":12.4,"mean":11.6,"avg7":12.1,"avg30":11.8},
      "HRV_RMSSD":{"count":45,"latest":52,"mean":51.2,"avg7":52.4,"avg30":50.6},
      "HEART_RATE_VARIABILITY":{"count":62,"latest":47.3,"mean":46.8,"avg7":null,"avg30":null}
    },"recoveryEmpty":null}
    """

    @Test("day strain and RMSSD resolve to the slice's avg30, not its latest")
    func wearableAverages() async throws {
        MockURLProtocol.install { req in
            #expect(req.url?.path == "/api/analytics")
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(Self.slice.utf8))
        }
        let repo = try makeRepository()
        #expect(await repo.average30(for: .dayStrain) == 11.8)
        #expect(await repo.average30(for: .hrvRMSSD) == 50.6)
    }

    @Test("a type without a reading in the last 30 days has no average")
    func stoppedTypeHasNoAverage() async throws {
        MockURLProtocol.install { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(Self.slice.utf8))
        }
        let repo = try makeRepository()
        #expect(await repo.average30(for: .hrv) == nil)
        #expect(await repo.average30(for: .weight) == nil, "A type the slice does not list has no average either.")
    }

    @Test("a failed read yields no average rather than an error on the page")
    func failedReadHasNoAverage() async throws {
        MockURLProtocol.install { _ in throw URLError(.notConnectedToInternet) }
        let repo = try makeRepository()
        #expect(await repo.average30(for: .dayStrain) == nil)
    }
}
