import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

// swiftlint:disable force_unwrapping

/// **v1.27.7 — the `selectedScoreRings` preserve-when-absent contract.**
///
/// The widgets PUT must send `selectedScoreRings` ONLY when the user changes the
/// hero rings; every other layout save (tile reorder / hide) must OMIT the field
/// so the server preserves the stored choice (older-client-safe). Verified at
/// two layers: the DTO encode (key present/absent) and the real wire body over
/// `APIClient` + `MockURLProtocol` (per PROJECT_GUIDE.md: real client, not a mock).
@Suite("selectedScoreRings PUT preserve-when-absent", .serialized)
struct DashboardScoreRingsSelectionPutTests {
    // MARK: - Helpers

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

    private func sampleLayout() -> DashboardWidgetLayout {
        DashboardWidgetLayout(widgets: [
            DashboardWidgetConfig(id: DashboardWidgetId.weight, visible: true, tileVisible: true, order: 0),
            DashboardWidgetConfig(id: DashboardWidgetId.bp, visible: true, tileVisible: true, order: 1)
        ])
    }

    private func encodeJSON(_ layout: DashboardWidgetLayout) throws -> String {
        try String(bytes: JSONEncoder.hlDefault.encode(layout), encoding: .utf8) ?? ""
    }

    // MARK: - DTO encode

    @Test("a tile reorder OMITS selectedScoreRings (preserve-when-absent)")
    func reorderOmitsField() throws {
        let reordered = sampleLayout().reordering([DashboardWidgetId.bp, DashboardWidgetId.weight])
        #expect(reordered.selectedScoreRings == nil)
        let json = try encodeJSON(reordered)
        #expect(!json.contains("selectedScoreRings"))
    }

    @Test("toggling tile visibility OMITS selectedScoreRings")
    func toggleOmitsField() throws {
        let toggled = sampleLayout().togglingTileVisibility(forId: DashboardWidgetId.weight)
        #expect(toggled.selectedScoreRings == nil)
        #expect(try !encodeJSON(toggled).contains("selectedScoreRings"))
    }

    @Test("a ring change SENDS selectedScoreRings (deduped, clamped, ordered)")
    func ringChangeSendsField() throws {
        let changed = sampleLayout().settingSelectedScoreRings(
            [.readiness, .readiness, .sleepScore, .recovery, .medCompliance]
        )
        // Deduped + clamped to the max of three, order preserved.
        #expect(changed.selectedScoreRings == ["READINESS", "SLEEP_SCORE", "RECOVERY_SCORE"])
        let json = try encodeJSON(changed)
        #expect(json.contains("selectedScoreRings"))
        #expect(json.contains("READINESS"))
    }

    @Test("resolvedScoreRingSelection: parses layout, defaults when absent")
    func resolvedSelection() {
        // Absent → server default (MED_COMPLIANCE).
        #expect(sampleLayout().resolvedScoreRingSelection == ScoreRingID.defaultSelection)
        // Present → parsed back into the closed set (unknown ids dropped).
        let withRings = DashboardWidgetLayout(
            widgets: sampleLayout().widgets,
            selectedScoreRings: ["SLEEP_SCORE", "BOGUS", "READINESS"]
        )
        #expect(withRings.resolvedScoreRingSelection == [.sleepScore, .readiness])
    }

    // MARK: - Real wire body (APIClient + MockURLProtocol)

    @Test("wire: reorder PUT body has no selectedScoreRings key")
    func wireReorderOmits() async throws {
        let body = try await capturePutBody(
            sampleLayout().reordering([DashboardWidgetId.bp, DashboardWidgetId.weight])
        )
        #expect(!body.contains("selectedScoreRings"))
    }

    @Test("wire: ring-change PUT body carries selectedScoreRings")
    func wireRingChangeSends() async throws {
        let body = try await capturePutBody(
            sampleLayout().settingSelectedScoreRings([.readiness, .medCompliance])
        )
        #expect(body.contains("selectedScoreRings"))
        #expect(body.contains("READINESS"))
        #expect(body.contains("MED_COMPLIANCE"))
    }

    /// Sends `layout` through the real `DashboardRepository.setWidgetLayout` over
    /// `MockURLProtocol` and returns the captured request-body JSON string.
    private func capturePutBody(_ layout: DashboardWidgetLayout) async throws -> String {
        let repo = DashboardRepository(api: makeAPI())
        let box = BodyBox()
        MockURLProtocol.handler = { req in
            let data = req.httpBody ?? Self.drainStream(req.httpBodyStream)
            box.set(data.flatMap { String(bytes: $0, encoding: .utf8) })
            // Echo a valid layout so the repo's decode succeeds.
            let echo = Data(#"{"version":1,"widgets":[],"selectedScoreRings":["MED_COMPLIANCE"]}"#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, echo)
        }
        _ = try await repo.setWidgetLayout(layout)
        return box.value ?? ""
    }

    /// `URLProtocol` moves a PUT body onto `httpBodyStream`; drain it.
    private static func drainStream(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buf, maxLength: 4096)
            if read <= 0 { break }
            data.append(buf, count: read)
        }
        return data
    }
}

/// Thread-safe one-shot capture of the request-body string.
private final class BodyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: String?
    func set(_ value: String?) {
        lock.lock()
        defer { lock.unlock() }
        storage = value
    }

    var value: String? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
