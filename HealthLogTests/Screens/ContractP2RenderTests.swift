import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// Server values the app decoded but did not show yet, now rendered
/// as delivered: the digest's `restMode`, `score.steadyWeeks` and `today[]`
/// (v1.40 / v1.40.2), the deviation `basis: sameHours` (v1.40.3), and the
/// Coach's reading window `coach-prefs.defaultWindow` (v1.40.2). Fixtures per
/// `docs/api/openapi.yaml` on `release/v1.43.0` (`d06ce3604`).
@MainActor
@Suite("Contract P2: digest facts, sameHours band, Coach window (#126)", .serialized, .mockURLSession)
struct ContractP2RenderTests {
    private static let env = AppEnvironment(
        baseURL: URL(string: "https://test.healthlog.local")!,
        bundleID: "dev.healthlog.app",
        appVersion: "1.3.0",
        buildNumber: "1"
    )

    private static func defaults() -> UserDefaults {
        UserDefaults(suiteName: "coachWindow.\(UUID().uuidString)")!
    }

    // MARK: - Digest

    private static func digest(_ extra: String) throws -> DailyDigest {
        let json = """
        {"date":"2026-10-16","lead":"Ein ruhiger Tag.","score":{"value":71,"band":"green","delta":null,"steadyWeeks":4,"steadyAtLeast":true},
         "restMode":{"day":3},
         "today":[{"kind":"sleep","label":"Schlaf","value":"7 h 10 min","href":"/sleep"},
                  {"kind":"restMode","label":"Erholung","value":"Tag 3","href":null}]\(extra)}
        """
        return try JSONDecoder.hlDefault.decode(DailyDigest.self, from: Data(json.utf8))
    }

    @Test("Rest Mode and the steady weeks get a footnote each; the facts come through as delivered")
    func digestLines() throws {
        let digest = try Self.digest("")
        let lines = TodayHeroFacts.footnotes(digest)
        #expect(lines == [
            String(localized: "today.restMode.day \(3)"),
            String(localized: "today.hero.steadyAtLeast \(4)")
        ])
        #expect(digest.today.map(\.label) == ["Schlaf", "Erholung"])
        #expect(digest.today.first?.value == "7 h 10 min")
    }

    @Test("A digest without them shows nothing extra")
    func digestWithoutExtras() throws {
        let json = #"{"date":"2026-10-16","lead":"x","score":{"value":71,"band":"green","delta":null}}"#
        let digest = try JSONDecoder.hlDefault.decode(DailyDigest.self, from: Data(json.utf8))
        #expect(TodayHeroFacts.footnotes(digest).isEmpty)
        #expect(digest.today.isEmpty)
    }

    // MARK: - sameHours

    @Test("A deviation on basis sameHours names the band for this time of day")
    func sameHoursBand() {
        #expect(InsightsHealthStatusCard.bandTemplate(basis: "sameHours")
            == String(localized: "clinicalSignals.healthStatus.band.sameHours"))
        #expect(InsightsHealthStatusCard.bandTemplate(basis: "day") == String(localized: "clinicalSignals.healthStatus.band"))
        #expect(InsightsHealthStatusCard.bandTemplate(basis: nil) == String(localized: "clinicalSignals.healthStatus.band"))
        #expect(InsightsHealthStatusCard.bandTemplate(basis: "weekly") == String(localized: "clinicalSignals.healthStatus.band"))
    }

    // MARK: - Coach window

    @Test("defaultWindow reads as stored; absent is allTime, an unknown word is not guessed")
    func windowDecodes() {
        #expect(CoachDefaultWindow.from(["defaultWindow": .string("lastYear")]) == .lastYear)
        #expect(CoachDefaultWindow.from([:]) == .allTime)
        #expect(CoachDefaultWindow.from(["defaultWindow": .string("lastDecade")]) == nil)
        #expect(CoachDefaultWindow.allCases.map(\.rawValue) == ["last7days", "last30days", "last90days", "lastYear", "allTime"])
    }

    @Test("Choosing a window writes only defaultWindow back, siblings kept")
    func windowWrite() async throws {
        let sent = SentBodies()
        MockURLProtocol.install { req in
            if req.httpMethod == "PUT" { sent.append(req) }
            let body = Data(#"""
            {"data":{"tone":"warm","verbosity":"brief","defaultWindow":"allTime","updatedAt":"2026-10-16T08:00:00.000Z"},"error":null}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let env = Self.env
        let kc = InMemoryKeychain()
        try? kc.setString("token", forKey: KeychainKey.authToken)
        let repo = AICoachSettingsRepository(api: APIClient(environment: env, keychain: kc, sessionConfiguration: .mock()))
        let store = AICoachSettingsStore(repo: repo, defaults: Self.defaults())
        await store.loadCoachDefaultWindow()
        #expect(store.coachDefaultWindow == .allTime)
        await store.setCoachDefaultWindow(.last90days)
        #expect(store.coachDefaultWindow == .last90days)
        let body = try #require(sent.all.last)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        #expect(json["defaultWindow"] as? String == "last90days")
        #expect(json["tone"] as? String == "warm")
        #expect(json["verbosity"] as? String == "brief")
        #expect(json["updatedAt"] == nil)
    }
}

private final class SentBodies: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []

    func append(_ request: URLRequest) {
        let data = request.httpBody ?? request.httpBodyStream.map { stream -> Data in
            stream.open()
            defer { stream.close() }
            var out = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                out.append(buffer, count: count)
            }
            return out
        }
        lock.withLock { items.append(data.flatMap { String(data: $0, encoding: .utf8) } ?? "") }
    }

    var all: [String] {
        lock.withLock { items }
    }
}
