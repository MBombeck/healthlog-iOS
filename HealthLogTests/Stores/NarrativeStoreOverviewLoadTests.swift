import Foundation
@testable import HealthLog
import Synchronization
import Testing

// swiftlint:disable force_unwrapping

/// BRIEFING-LOAD-FIX (v0.14.8) — locks the on-appear load path that backs the
/// Insights overview "Tagesbriefing" prose.
///
/// **Why this exists.** `InsightsScreen.generalHealthReportText` falls back from
/// `DailyBriefingStore.summary` (AI-provider-only) to the deterministic `.week`
/// period NARRATIVE so prose appears even for a provider-less account. Before
/// this fix nothing loaded `NarrativeStore` on the overview's `.task` (the
/// self-loading "Zeitraum im Rückblick" card that used to warm it was removed in
/// v0.14.9), so the Tagesbriefing stayed empty until a manual pull-to-refresh.
/// The screen now warms `.week` on appear + scenePhase-active via
/// `loadOverviewNarrative()`.
///
/// These tests lock the store-level contract that warm relies on:
/// - `load(period: .week)` settles a present narrative → `narrative(for:)`
///   returns the prose the overview slot reads (no manual pull needed).
/// - a `revalidating: true, narrative: null` envelope (server still generating)
///   does NOT settle the period; it sets `warming` + the bounded re-poll picks
///   up the freshly-warmed narrative in the SAME session.
/// - the warm re-poll is bounded (no tight loop) — battery-safe.
@MainActor
@Suite("NarrativeStore — overview Tagesbriefing on-appear load", .serialized)
struct NarrativeStoreOverviewLoadTests {
    private func makeAPI() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.14.8",
            buildNumber: "1"
        )
        return APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
    }

    /// A narrative envelope with the given `revalidating` + optional prose.
    /// `nonisolated static` so the off-actor `MockURLProtocol` handler can call it.
    private nonisolated static func body(revalidating: Bool, text: String?) -> Data {
        let narrativeJSON = text.map {
            "{\"text\":\"\($0)\",\"updatedAt\":\"2026-06-03T06:00:00Z\"}"
        } ?? "null"
        let revJSON = revalidating ? "true" : "false"
        return Data(#"""
        {"data":{"period":"week","locale":"de",
          "narrative":\#(narrativeJSON),
          "revalidating":\#(revJSON)},"error":null}
        """#.utf8)
    }

    @Test("load(.week) settles the narrative → overview prose is available without a pull")
    func loadSettlesNarrative() async {
        let repo = NarrativeRepository(api: makeAPI())
        let store = NarrativeStore(repo: repo)
        MockURLProtocol.handler = { req in
            (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Self.body(revalidating: false, text: "Diese Woche lag dein Blutdruck stabil im Zielbereich.")
            )
        }

        // Cold store (what the overview sees on first appear) → empty.
        #expect(store.narrative(for: .week) == nil)

        // The on-appear warm.
        await store.load(period: .week, locale: "de")

        // The prose the Tagesbriefing slot reads is now present — no pull needed.
        #expect(store.narrative(for: .week)?.text.contains("Blutdruck") == true)
        #expect(store.isWarming(.week) == false)
        #expect(store.hasSettled(.week) == true)
    }

    @Test("revalidating:true → warming + bounded re-poll picks up the warmed narrative in-session")
    func warmingThenSettles() async throws {
        let repo = NarrativeRepository(api: makeAPI())
        let store = NarrativeStore(repo: repo)

        // First read: server still generating (revalidating:true, narrative:null).
        // The scheduled re-poll: settled with prose.
        let callCount = Counter()
        MockURLProtocol.handler = { req in
            let n = callCount.next()
            let body = n == 0
                ? Self.body(revalidating: true, text: nil)
                : Self.body(revalidating: false, text: "Dein Ruhepuls hat sich diese Woche leicht verbessert.")
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }

        await store.load(period: .week, locale: "de")
        // First load saw revalidating:true → warming, not yet settled.
        #expect(store.isWarming(.week) == true)
        #expect(store.narrative(for: .week) == nil)
        #expect(store.hasSettled(.week) == false)

        // The re-poll is delayed (~4s); poll until it settles in-session.
        try await waitUntil { store.narrative(for: .week) != nil }
        #expect(store.isWarming(.week) == false)
        #expect(store.narrative(for: .week)?.text.contains("Ruhepuls") == true)
    }

    @Test("warm re-poll is bounded — a never-settling server does not loop forever")
    func warmRepollIsBounded() async throws {
        let repo = NarrativeRepository(api: makeAPI())
        let store = NarrativeStore(repo: repo)

        // The server ALWAYS returns revalidating:true, narrative:null. The store
        // must cap its re-polls and settle the period empty (battery-safe), not
        // spin a tight loop.
        let callCount = Counter()
        MockURLProtocol.handler = { req in
            _ = callCount.next()
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Self.body(revalidating: true, text: nil)
            )
        }

        await store.load(period: .week, locale: "de")
        #expect(store.isWarming(.week) == true)

        // After the bounded re-poll window the period settles empty + warming clears.
        try await waitUntil { store.hasSettled(.week) }
        #expect(store.isWarming(.week) == false)
        #expect(store.narrative(for: .week) == nil)
        // The call count is bounded (initial + capped re-polls = 1 + 3), never
        // unbounded — proves the re-poll is battery-safe, not a tight loop.
        #expect(callCount.peek() <= 4)
    }

    // MARK: - Helpers

    /// Polls `condition` every 50ms up to ~30s (the re-poll delay is ~4s, capped
    /// at 3 → worst-case ~12s for the bounded-exhaustion case).
    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0 ..< 600 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("Condition never became true within the timeout")
    }

    /// Thread-safe call counter for the mock handler (it runs off-actor).
    private final class Counter: Sendable {
        private let value = Mutex(0)
        func next() -> Int {
            value.withLock { current in
                defer { current += 1 }
                return current
            }
        }

        func peek() -> Int {
            value.withLock { $0 }
        }
    }
}
