import Foundation

// swiftlint:disable force_unwrapping force_try
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// v1.28 (GH iOS #45) — the medication-efficacy ("Wirkung") repository seam.
///
/// Uses the **real `APIClient` over a stubbed `URLSession`** (`MockURLProtocol`),
/// per PROJECT_GUIDE.md — never a mock server — so the DTO decodes against the exact
/// server wire shape and any schema drift is caught. Coverage:
///   - the resolved efficacy DTO decodes the real `{ data: … }` envelope with
///     markers + before/after + adherence + override options,
///   - a `404` (route absent on an older server) resolves to `nil` so the
///     section self-suppresses (never a thrown error),
///   - the target PUT round-trips both a metric pin and a clear.
@Suite("MedicationsRepository+Efficacy (v1.28 / GH iOS #45)", .serialized)
struct MedicationsRepositoryEfficacyTests {
    private func makeAPI() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            cfAccessClientID: nil,
            cfAccessClientToken: nil,
            bundleID: "dev.healthlog.app",
            appVersion: "0.1.0",
            buildNumber: "1"
        )
        return APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
    }

    private func makeRepo(_ api: APIClient) throws -> MedicationsRepository {
        try MedicationsRepository(api: api, outbox: OutboxQueue(inMemory: true))
    }

    /// The real enveloped efficacy payload: one pinned metric target with a
    /// reference band + a three-point series, a present before/after with a
    /// delta, a near-start level shift, start/dose-change/pause markers, an
    /// adherence lane, and retarget options.
    private let efficacyJSON = """
    {
      "data": {
        "medicationId": "med-1",
        "medicationName": "Lisinopril",
        "eligible": true,
        "startsOn": "2026-01-15",
        "resolution": { "tier": "override", "cls": "C09AA" },
        "windowDays": 180,
        "minWeeksPerSide": 4,
        "markers": {
          "start": "2026-01-15",
          "startSource": "startsOn",
          "doseChanges": [ { "at": "2026-02-10T00:00:00Z", "label": "5 mg" } ],
          "pauses": [ { "from": "2026-03-01T00:00:00Z", "to": "2026-03-08T00:00:00Z" } ]
        },
        "targets": [
          {
            "kind": "metric",
            "key": "BLOOD_PRESSURE_SYS",
            "label": "Blutdruck systolisch",
            "unit": "mmHg",
            "primary": true,
            "referenceBand": { "low": 110, "high": 130 },
            "series": [
              { "t": "2026-01-01T00:00:00Z", "value": 148, "status": "above" },
              { "t": "2026-02-01T00:00:00Z", "value": 138, "status": "above" },
              { "t": "2026-03-01T00:00:00Z", "value": 128, "status": "in-range" }
            ],
            "beforeAfter": {
              "present": true,
              "before": { "mean": 147.5, "count": 6, "from": "2025-12-15", "to": "2026-01-14" },
              "after": { "mean": 131.2, "count": 9, "from": "2026-01-16", "to": "2026-03-01" },
              "delta": { "mean": -16.3, "pct": -11.1 }
            },
            "levelShift": { "present": true, "at": "2026-01-20T00:00:00Z", "nearStart": true }
          }
        ],
        "adherence": [
          { "date": "2026-02-01", "rate": 100, "taken": 1, "missed": 0 },
          { "date": "2026-02-02", "rate": 0, "taken": 0, "missed": 1 }
        ],
        "overrideOptions": {
          "metrics": [ { "key": "PULSE", "label": "Puls" } ],
          "biomarkers": [ { "id": "bio-ldl", "label": "LDL-Cholesterin", "unit": "mg/dL" } ]
        }
      },
      "error": null
    }
    """

    @Test("Efficacy DTO decodes the real enveloped shape with all marker sets")
    func efficacyDTODecodes() async throws {
        let api = makeAPI()
        let repo = try makeRepo(api)
        MockURLProtocol.handler = { req in
            (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(efficacyJSON.utf8)
            )
        }

        let dto = await repo.efficacy(medicationID: "med-1")
        let efficacy = try #require(dto)

        #expect(efficacy.eligible)
        #expect(efficacy.medicationName == "Lisinopril")
        #expect(efficacy.resolution.isOverride)
        #expect(efficacy.minWeeksPerSide == 4)

        // Markers
        #expect(efficacy.markers.start != nil)
        #expect(efficacy.markers.startSource == "startsOn")
        #expect(efficacy.markers.startFromFirstReading == false)
        #expect(efficacy.markers.doseChanges.count == 1)
        #expect(efficacy.markers.doseChanges.first?.label == "5 mg")
        #expect(efficacy.markers.pauses.count == 1)
        #expect(efficacy.markers.pauses.first?.to != nil)

        // Target + series
        let target = try #require(efficacy.targets.first)
        #expect(target.primary)
        #expect(target.unit == "mmHg")
        #expect(target.series.count == 3)
        #expect(target.referenceBand?.low == 110)

        // Before/after
        #expect(target.beforeAfter.isRenderable)
        #expect(target.beforeAfter.before?.count == 6)
        #expect(target.beforeAfter.after?.mean == 131.2)
        #expect(target.beforeAfter.delta?.mean == -16.3)

        // Level shift
        #expect(target.levelShift?.isNearStart == true)

        // Adherence
        #expect(efficacy.adherence.count == 2)
        #expect(efficacy.adherence.map(\.taken).reduce(0, +) == 1)
        #expect(efficacy.adherence.map { $0.taken + $0.missed }.reduce(0, +) == 2)

        // Retarget options
        #expect(efficacy.overrideOptions.metrics.count == 1)
        #expect(efficacy.overrideOptions.biomarkers.first?.id == "bio-ldl")
        #expect(efficacy.overrideOptions.isEmpty == false)
    }

    @Test("A 404 resolves to nil — feature absent, section self-suppresses")
    func efficacy404ResolvesToNil() async throws {
        let api = makeAPI()
        let repo = try makeRepo(api)
        MockURLProtocol.handler = { req in
            (
                HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!,
                Data(#"{"data":null,"error":"not found"}"#.utf8)
            )
        }

        let dto = await repo.efficacy(medicationID: "med-unknown")
        #expect(dto == nil)
    }

    @Test("A thin/ineligible DTO decodes but drives suppression via eligible=false")
    func efficacyIneligibleDecodes() async throws {
        let api = makeAPI()
        let repo = try makeRepo(api)
        let json = """
        {
          "data": {
            "medicationId": "med-2",
            "medicationName": "Naproxen",
            "eligible": false,
            "reason": "one_shot",
            "startsOn": null,
            "resolution": { "tier": "none", "cls": null },
            "windowDays": 180,
            "minWeeksPerSide": 4,
            "markers": { "start": null, "startSource": null, "doseChanges": [], "pauses": [] },
            "targets": [],
            "adherence": [],
            "overrideOptions": { "metrics": [], "biomarkers": [] }
          },
          "error": null
        }
        """
        MockURLProtocol.handler = { req in
            (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(json.utf8)
            )
        }

        let dto = try #require(await repo.efficacy(medicationID: "med-2"))
        #expect(dto.eligible == false)
        #expect(dto.reason == "one_shot")
        #expect(dto.markers.start == nil)
        #expect(dto.targets.isEmpty)
    }

    @Test("Target PUT round-trips a metric pin")
    func setTargetMetricRoundTrips() async throws {
        let api = makeAPI()
        let repo = try makeRepo(api)
        let seenMethod = MethodBox()
        MockURLProtocol.handler = { req in
            seenMethod.set(req.httpMethod)
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"data":{"ok":true,"cleared":false},"error":null}"#.utf8)
            )
        }

        let result = try await repo.setEfficacyTarget(medicationID: "med-1", selection: .metric("PULSE"))
        #expect(result.ok == true)
        #expect(result.cleared == false)
        #expect(seenMethod.value == "PUT")
    }

    @Test("Target PUT round-trips a clear")
    func clearTargetRoundTrips() async throws {
        let api = makeAPI()
        let repo = try makeRepo(api)
        MockURLProtocol.handler = { req in
            (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"data":{"ok":true,"cleared":true},"error":null}"#.utf8)
            )
        }

        let result = try await repo.setEfficacyTarget(medicationID: "med-1", selection: .clear)
        #expect(result.cleared == true)
    }

    /// Thread-safe capture of the last HTTP method the stub saw.
    private final class MethodBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: String?
        func set(_ value: String?) {
            lock.lock()
            defer { lock.unlock() }
            stored = value
        }

        var value: String? {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }
}

// swiftlint:enable force_unwrapping force_try
