import Foundation
@testable import HealthLog
import Testing

/// **v0.8.4 WWIDGET-3** — pins the one-shot "Erfassen"-control hand-off.
///
/// The `OpenCaptureIntent` writes a marker; the app consumes it on
/// foreground. Contract: write → consume returns the request exactly once,
/// the file is cleared on consume, a stale marker is ignored, and a nil
/// container / missing file degrades to `nil` without throwing.
@Suite("CaptureRequestStore — one-shot capture hand-off")
struct CaptureRequestStoreTests {
    private func makeURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("capture-request-\(UUID().uuidString).json")
    }

    @Test("Write then consume returns the request once, then nil")
    func writeConsumeIsOneShot() throws {
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = CaptureRequestStore(url: url)

        // Whole-second date so the ISO-8601 round-trip (no fractional
        // seconds) is bit-exact — the marker only needs second precision.
        // Consume against a `now` inside the freshness window of that date.
        let requestedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let now = requestedAt.addingTimeInterval(2)
        let written = CaptureRequestStore.Request(requestedAt: requestedAt)
        try store.write(written)

        let first = store.consume(now: now)
        #expect(first == written)

        // One-shot: the marker is cleared, a second consume sees nothing.
        #expect(store.consume(now: now) == nil)
    }

    @Test("A stale marker is ignored")
    func staleMarkerIgnored() throws {
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = CaptureRequestStore(url: url)

        // Deterministic whole-second clock; the marker is written `staleAfter
        // + 10s` in the past relative to the injected `now`.
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let old = CaptureRequestStore.Request(
            requestedAt: now.addingTimeInterval(-(CaptureRequestStore.staleAfter + 10))
        )
        try store.write(old)

        #expect(store.consume(now: now) == nil)
        // Even an ignored stale marker is cleared from disk.
        #expect(FileManager.default.fileExists(atPath: url.path) == false)
    }

    @Test("A fresh-but-just-inside-window marker is honoured")
    func freshMarkerHonoured() throws {
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = CaptureRequestStore(url: url)

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let request = CaptureRequestStore.Request(
            requestedAt: now.addingTimeInterval(-(CaptureRequestStore.staleAfter - 5))
        )
        try store.write(request)

        #expect(store.consume(now: now) == request)
    }

    @Test("Consuming a missing file returns nil, not a crash")
    func consumeMissingFile() {
        let store = CaptureRequestStore(url: makeURL())
        #expect(store.consume() == nil)
    }

    @Test("A nil container makes write a no-op and consume nil")
    func nilContainerIsSafe() throws {
        let store = CaptureRequestStore(url: nil)
        try store.write() // must not throw
        #expect(store.consume() == nil)
    }

    // MARK: - v0.10.0 W-Mood-B — surface routing

    @Test("The marker surface round-trips (mood is preserved through write/consume)")
    func surfaceRoundTrips() throws {
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = CaptureRequestStore(url: url)

        let requestedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let now = requestedAt.addingTimeInterval(2)
        let mood = CaptureRequestStore.Request(requestedAt: requestedAt, surface: .mood)
        try store.write(mood)

        let consumed = store.consume(now: now)
        #expect(consumed?.surface == .mood)
        #expect(consumed == mood)
    }

    @Test("The default surface is capture")
    func defaultSurfaceIsCapture() {
        let request = CaptureRequestStore.Request(requestedAt: .now)
        #expect(request.surface == .capture)
    }

    @Test("A legacy (surface-less) marker decodes as capture")
    func legacyMarkerDefaultsToCapture() throws {
        // The pre-W-Mood-B marker shape carried only `requestedAt`. A control
        // tap from an older app build must still route to capture.
        let legacy = #"{"requestedAt":"2023-11-14T22:13:20Z"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let request = try decoder.decode(
            CaptureRequestStore.Request.self,
            from: Data(legacy.utf8)
        )
        #expect(request.surface == .capture)
    }
}
