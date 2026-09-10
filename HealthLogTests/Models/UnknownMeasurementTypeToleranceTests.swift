import Foundation
import Testing

#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

// swiftlint:disable force_unwrapping

/// **Audit B-4 (2026-09-10) — a measurement value this build does not know must
/// degrade, never drop.**
///
/// Three ways to lose a row, all silent. `AUDIO_EXPOSURE_EVENT` is the 77th
/// server `MeasurementType` and the only one without a `MetricKind`, so
/// `toDomain()` returns `nil` and the row never reaches a list. A `type` the
/// server adds after this build throws inside `MeasurementWireDTO`, which
/// `TolerantMeasurementWire` catches by discarding the whole row. So does a
/// `source` — the one that has actually fired, four releases running. In every
/// case the app shows fewer measurements than the server holds and says nothing.
///
/// Real `APIClient` + `MockURLProtocol` so the whole read path runs (PROJECT_GUIDE.md
/// anti-pattern: no mock-server). `.serialized` because the network assertion
/// depends on the process-global `MockURLProtocol.handler` (audit-v0162 H2).
@Suite("Audit B-4 — unknown measurement values degrade instead of dropping", .serialized)
struct UnknownMeasurementTypeToleranceTests {
    private func makeRepo() throws -> MeasurementsRepository {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.1.0",
            buildNumber: "1"
        )
        return try MeasurementsRepository(
            api: APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock()),
            outbox: OutboxQueue(inMemory: true)
        )
    }

    private func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func respond(_ rows: String) {
        let payload = Data("{\"data\":{\"measurements\":[\(rows)]}}".utf8)
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, payload)
        }
    }

    // MARK: - A type the server added after this build

    @Test("A row whose type this build does not know survives the list decode")
    func futureTypeRowSurvives() async throws {
        let repo = try makeRepo()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        respond(
            "{\"id\":\"future-1\",\"type\":\"FUTURE_VALUE\",\"value\":42,\"measuredAt\":\"\(iso(now))\"}," +
                "{\"id\":\"w-1\",\"type\":\"WEIGHT\",\"value\":80," +
                "\"measuredAt\":\"\(iso(now.addingTimeInterval(-3600)))\"}"
        )

        let rows = try await repo.recent(limit: 100)

        #expect(rows.count == 2, "The unknown-type row must be carried, not discarded with the page's row count.")
        #expect(rows.contains { $0.id == "future-1" })
    }

    @Test("A row whose type this build does not know is never fabricated onto a known kind")
    func futureTypeRowClaimsNoKind() async throws {
        let repo = try makeRepo()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        respond("{\"id\":\"future-2\",\"type\":\"FUTURE_VALUE\",\"value\":42,\"measuredAt\":\"\(iso(now))\"}")

        let rows = try await repo.recent(limit: 100)
        let row = try #require(rows.first)

        #expect(rows.count == 1)
        // Whatever kind it lands on, it must not be a real metric: an unknown
        // reading on a known axis is worse than a dropped one.
        #expect(row.kind == .unknown)
        #expect(row.kind.isUnknown)
        #expect(row.kind.unit.isEmpty)
        // The value the server sent is carried verbatim — degrading the LABEL
        // must not degrade the DATA.
        #expect(row.value == .scalar(42))
    }

    @Test("The unknown kind is never offered to a person and never exported")
    func unknownKindIsQuarantined() {
        // Not enumerable: no picker row, no coach digest line, no tab-strip pill.
        #expect(!MetricKind.selectableCases.contains(.unknown))
        #expect(MetricKind.allCases.contains(.unknown), "…but an existing row can still be mapped through it")
        // Nothing computes with it: no unit, no plausible range, no benchmark,
        // no series query, no LOINC.
        #expect(MetricKind.unknown.unit.isEmpty)
        #expect(MeasurementRanges.range(for: .unknown) == nil)
        #expect(MetricFHIRMapper.mapping(for: .unknown) == nil)
        #expect(LiveClinicalBenchmarkProvider().benchmark(for: .unknown) == nil)
        #expect(!ChartDetailStore.kindSupportsSeries(.unknown))
        // And it has no summaries key, so it can never claim "this kind has data".
        #expect(MetricKind.unknown.availabilitySummaryKey == nil)
    }

    @Test("The unknown sentinel decodes from any raw value but refuses to be sent back")
    func unknownSentinelNeverLeavesTheDevice() throws {
        let decoded = try JSONDecoder().decode(ServerMeasurementType.self, from: Data("\"FUTURE_VALUE\"".utf8))
        #expect(decoded == .unknown)
        // A known value is unaffected by the tolerant path.
        #expect(try JSONDecoder().decode(ServerMeasurementType.self, from: Data("\"WEIGHT\"".utf8)) == .weight)
        // `__UNKNOWN__` is not a server token and must never be written.
        #expect(throws: EncodingError.self) {
            _ = try JSONEncoder().encode(ServerMeasurementType.unknown)
        }
        #expect(!ServerMeasurementType.serverCases.contains(.unknown))
    }

    @Test("A single-measurement decode tolerates an unknown type instead of failing whole")
    func singleMeasurementDecodeSurvives() throws {
        // The list path has a tolerant wrapper; the POST / PATCH / GET-by-id
        // path has none, so before the sentinel existed an unknown type there
        // failed the entire response as `HLError.decoding`.
        let json = "{\"id\":\"single-1\",\"type\":\"FUTURE_VALUE\",\"value\":7," +
            "\"measuredAt\":\"2026-09-01T08:00:00Z\"}"
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let wire = try decoder.decode(MeasurementWireDTO.self, from: Data(json.utf8))
        #expect(wire.type == .unknown)
        #expect(wire.toDomain()?.kind == .unknown)
    }

    // MARK: - The other half of the row: an unknown SOURCE

    @Test("A row whose source this build does not know survives the list decode")
    func futureSourceRowSurvives() async throws {
        // The same failure mode as an unknown type, and the one that has
        // actually fired: COMPUTED, then STRAVA/OURA/POLAR/NIGHTSCOUT, then
        // TELEGRAM/MCP, then EXTERNAL — four releases, each one silently
        // costing every row written by the integration it names.
        let repo = try makeRepo()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        respond(
            "{\"id\":\"src-1\",\"type\":\"WEIGHT\",\"value\":80,\"source\":\"FUTURE_INTEGRATION\"," +
                "\"measuredAt\":\"\(iso(now))\"}," +
                "{\"id\":\"src-2\",\"type\":\"WEIGHT\",\"value\":81,\"source\":\"MANUAL\"," +
                "\"measuredAt\":\"\(iso(now.addingTimeInterval(-3600)))\"}"
        )

        let rows = try await repo.recent(limit: 100)

        #expect(rows.count == 2, "The unknown-source row must be carried, not discarded.")
        let row = try #require(rows.first { $0.id == "src-1" })
        #expect(row.source == .unknown)
        // The reading itself is intact — only the provenance label degrades.
        #expect(row.kind == .weight)
        #expect(row.value == .scalar(80))
        // Server-owned until proven otherwise: no value-edit affordance, and it
        // never writes itself into Apple Health.
        #expect(row.isServerDerivedReadOnly)
        #expect(!MeasurementSource.unknown.isServerMirrorEligible)
        #expect(!MeasurementSource.serverMirrorEligible.contains(.unknown))
    }

    @Test("The unknown source decodes from any raw value but refuses to be sent back")
    func unknownSourceNeverLeavesTheDevice() throws {
        let decoded = try JSONDecoder().decode(ServerMeasurementSource.self, from: Data("\"FUTURE_X\"".utf8))
        #expect(decoded == .unknown)
        #expect(try JSONDecoder().decode(ServerMeasurementSource.self, from: Data("\"MANUAL\"".utf8)) == .manual)
        #expect(throws: EncodingError.self) {
            _ = try JSONEncoder().encode(ServerMeasurementSource.unknown)
        }
        #expect(!ServerMeasurementSource.serverCases.contains(.unknown))
        #expect(ServerMeasurementSource.unknown.toDomain() == .unknown)
        #expect(MeasurementSource.unknown.wire == .unknown)
    }

    // MARK: - Fix round 1 — the sentinel never reaches a query string

    @Test("The blood-pressure page filtered by the unknown source sends no sourceEq")
    func unknownSourceNeverReachesTheBloodPressureQuery() async throws {
        // `+Reads.swift` already refused to send `__UNKNOWN__`; the paired
        // blood-pressure page appended it unconditionally, and the source chip
        // on a BP list reaches exactly that path. A server that validates
        // `sourceEq` against `measurementSourceEnum` answers 400.
        // Per-instance transport, not the process-global handler: this case
        // issues `/api/measurements` GETs, and a suite counting requests on
        // that same path in parallel would otherwise attribute them to itself
        // (audit-v0162 H2 / issue #82 — `MockURLProtocolSession`).
        let session = MockURLProtocolSession()
        defer { session.invalidate() }
        let repo = try MeasurementsRepository(
            api: APIClient(
                environment: AppEnvironment(
                    baseURL: session.baseURL,
                    bundleID: "dev.healthlog.app",
                    appVersion: "0.1.0",
                    buildNumber: "1"
                ),
                keychain: InMemoryKeychain(),
                sessionConfiguration: session.configuration
            ),
            outbox: OutboxQueue(inMemory: true)
        )
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let seen = RecordedQueries()
        let nowStamp = iso(now)
        let earlierStamp = iso(now.addingTimeInterval(-3600))
        var wireRows: [String] = []
        wireRows.append(Self.bpRow(id: "sys-u", type: "BLOOD_PRESSURE_SYS", value: 124, source: "FUTURE_X", at: nowStamp))
        wireRows.append(Self.bpRow(id: "dia-u", type: "BLOOD_PRESSURE_DIA", value: 78, source: "FUTURE_X", at: nowStamp))
        wireRows.append(Self.bpRow(id: "sys-m", type: "BLOOD_PRESSURE_SYS", value: 130, source: "MANUAL", at: earlierStamp))
        wireRows.append(Self.bpRow(id: "dia-m", type: "BLOOD_PRESSURE_DIA", value: 85, source: "MANUAL", at: earlierStamp))
        let body = Data("{\"data\":{\"measurements\":[\(wireRows.joined(separator: ","))]}}".utf8)
        session.install { req in
            seen.record(req.url?.query)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }

        let rows = try await repo.recent(kind: .bloodPressure, limit: 100, source: .unknown)

        #expect(seen.queries.allSatisfy { !$0.contains("sourceEq") }, "queries were: \(seen.queries)")
        #expect(!seen.queries.isEmpty, "the page must actually have been fetched")
        // Fetching unfiltered means the filter has to be applied here instead.
        #expect(rows.allSatisfy { $0.source == .unknown }, "an unfiltered page must not leak other sources")
        #expect(rows.contains { $0.id == "sys-u" })
    }

    private static func bpRow(id: String, type: String, value: Int, source: String, at stamp: String) -> String {
        let fields = [
            "\"id\":\"\(id)\"",
            "\"type\":\"\(type)\"",
            "\"value\":\(value)",
            "\"source\":\"\(source)\"",
            "\"measuredAt\":\"\(stamp)\""
        ]
        return "{\(fields.joined(separator: ","))}"
    }

    // MARK: - AUDIO_EXPOSURE_EVENT — the 77th server type

    @Test("An AUDIO_EXPOSURE_EVENT row survives the list decode")
    func audioExposureEventRowSurvives() async throws {
        let repo = try makeRepo()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        respond(
            "{\"id\":\"audio-1\",\"type\":\"AUDIO_EXPOSURE_EVENT\",\"value\":1,\"measuredAt\":\"\(iso(now))\"}," +
                "{\"id\":\"w-2\",\"type\":\"WEIGHT\",\"value\":80," +
                "\"measuredAt\":\"\(iso(now.addingTimeInterval(-3600)))\"}"
        )

        let rows = try await repo.recent(limit: 100)

        #expect(rows.count == 2, "The audio-exposure event row must be carried, not discarded.")
        #expect(rows.contains { $0.id == "audio-1" && $0.kind == .audioExposureEvent })
    }
}

/// Thread-safe URL-query recorder for the `MockURLProtocol` handler, which the
/// URL loading system calls off the test's own actor.
private final class RecordedQueries: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func record(_ query: String?) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(query ?? "")
    }

    var queries: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

// swiftlint:enable force_unwrapping
