import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// QC-1 / Arch-H3 reconcile-coverage:
///
/// `OnDeviceBriefingCache` + `TrendObservationCache` were singletons backed
/// by `UserDefaults.standard`, and `AppContainer.handleLocalLogout` never
/// called them. A user signing out → another user signing in on the same
/// device would see stale briefing copy + cached trend strings until
/// next-day key rollover.
///
/// Post-reconcile both caches gain a `clearOnLogout()` that wipes every
/// prefixed key, and `handleLocalLogout` calls both. Internally the
/// caches also swap `@unchecked Sendable` for an `NSLock`-guarded barrier
/// around mutations to keep the dictionary-snapshot-then-remove pattern
/// race-free across `write` / `clearOnLogout` overlap.
@Suite("On-device AI caches — logout clears, locked writes")
struct OnDeviceCacheLogoutTests {
    /// v0.9.0 — `OnDeviceBriefingCache` now persists to a file-protected JSON
    /// store (off `UserDefaults`); the test seam injects a throwaway temp
    /// directory.
    private func makeTempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("test.briefing.\(UUID().uuidString)", isDirectory: true)
    }

    @Test("OnDeviceBriefingCache.clearOnLogout drops every cached key")
    func briefingCacheClearOnLogout() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = OnDeviceBriefingCache(directory: dir)

        // write() evicts older keys on each call; only the most-recent key is
        // hot — but clearOnLogout must wipe even that one.
        let key1 = "ondevice_briefing.2026-05-15.de"
        let key3 = "ondevice_briefing.2026-05-17.de"
        let briefing = DailyBriefing(paragraph: "Test", keyFindings: [])
        cache.write(briefing, for: key1)
        cache.write(briefing, for: key3)
        #expect(cache.read(for: key3) != nil, "most-recent must be hot pre-clear")
        #expect(cache.read(for: key1) == nil, "older key auto-expires on next write")

        cache.clearOnLogout()

        #expect(cache.read(for: key3) == nil, "clearOnLogout must drop the most-recent cached key too")
    }

    @Test("TrendObservationCache.clearOnLogout drops every prefixed key")
    func trendCacheClearOnLogout() {
        // v0.12 P3 (QoS-M1) — the trend cache now persists to a file-protected
        // JSON store (off UserDefaults); the seam injects a temp directory.
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = TrendObservationCache(directory: dir)

        let obs = TrendObservation(
            observation: "Trend Test",
            metric: .pulse,
            delta: 1.0,
            direction: .stable,
            confidence: 0.8,
            safetyApplied: false
        )
        cache.write(obs, for: "pulse.de.2026-05-15")
        cache.write(obs, for: "pulse.de.2026-05-16")
        cache.write(obs, for: "weight.de.2026-05-16")

        // Pre-clear: all three coexist (multi-entry, no auto-expire).
        #expect(cache.read(for: "pulse.de.2026-05-15") != nil)
        #expect(cache.read(for: "weight.de.2026-05-16") != nil)

        cache.clearOnLogout()

        #expect(cache.read(for: "pulse.de.2026-05-15") == nil)
        #expect(cache.read(for: "pulse.de.2026-05-16") == nil)
        #expect(cache.read(for: "weight.de.2026-05-16") == nil)
    }

    @Test("OnDeviceBriefingCache round-trips a write then clears it (file store)")
    func briefingCacheRoundTrip() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = OnDeviceBriefingCache(directory: dir)

        cache.write(DailyBriefing(paragraph: "x"), for: "ondevice_briefing.2026-05-17.de")
        #expect(cache.read(for: "ondevice_briefing.2026-05-17.de")?.paragraph == "x")

        cache.clearOnLogout()
        #expect(cache.read(for: "ondevice_briefing.2026-05-17.de") == nil)
    }

    @Test("TrendObservationCache concurrent writes + clearOnLogout don't crash or hang")
    func trendCacheConcurrentMutate() async {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = TrendObservationCache(directory: dir)
        let obs = TrendObservation(
            observation: "Hammer",
            metric: .pulse,
            delta: 1.0,
            direction: .stable,
            confidence: 0.8,
            safetyApplied: false
        )

        // Drive 50 writes interleaved with 5 clears on independent tasks.
        await withTaskGroup(of: Void.self) { group in
            for i in 0 ..< 50 {
                group.addTask { cache.write(obs, for: "race.de.k\(i)") }
            }
            for _ in 0 ..< 5 {
                group.addTask { cache.clearOnLogout() }
            }
            for await _ in group {}
        }

        // Final clear so the invariant is "after a clear, the namespace is empty".
        cache.clearOnLogout()
        for i in 0 ..< 50 {
            #expect(cache.read(for: "race.de.k\(i)") == nil)
        }
    }
}

// swiftlint:enable force_unwrapping
