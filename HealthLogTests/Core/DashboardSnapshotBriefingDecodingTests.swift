import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// Locks the v1.16.x tolerant-first briefing slot decode off
/// `GET /api/dashboard/snapshot` (GH issue #15):
///
/// 1. Unknown `briefingState` raw values map to `.unknown` — NEVER a
///    `DecodingError` that would poison the whole snapshot.
/// 2. Absent `briefingStale` decodes as `false` (compat ≤v1.15.19).
/// 3. `briefingStale: true` carries the LAST generated text + timestamp →
///    the render policy is stale prose with that timestamp, not "preparing".
/// 4. `no-provider` renders the deterministic fallback (b155 A3
///    period-narrative path) — never a preparing state.
@Suite("DashboardSnapshotBriefing decode")
struct DashboardSnapshotBriefingDecodingTests {
    private let decoder = JSONDecoder.hlDefault

    /// Wire fixture mirroring the snapshot payload (extra snapshot fields
    /// included to prove the thin projection ignores them).
    private func payload(
        briefing: String = "null",
        state: String?,
        updatedAt: String = "null",
        stale: String? = nil
    ) -> Data {
        var fields = [
            "\"user\": {\"username\": \"anna\"}",
            "\"tiles\": {}",
            "\"layoutCatalogue\": [\"healthScore\"]",
            "\"briefing\": \(briefing)",
            "\"briefingUpdatedAt\": \(updatedAt)",
            "\"generatedAt\": \"2026-06-11T06:00:00.000Z\""
        ]
        if let state {
            fields.append("\"briefingState\": \"\(state)\"")
        }
        if let stale {
            fields.append("\"briefingStale\": \(stale)")
        }
        return Data("{\(fields.joined(separator: ","))}".utf8)
    }

    private static let briefingJSON = #"""
    {
        "paragraph": "Blutdruck stabil bei 124/82, Stimmung im 7-Tage-Mittel gut.",
        "keyFindings": []
    }
    """#

    @Test("Known briefingState raws decode to their typed cases")
    func knownStatesDecode() throws {
        for (raw, expected) in [
            ("ready", DashboardBriefingState.ready),
            ("preparing", .preparing),
            ("disabled", .disabled),
            ("no-provider", .noProvider)
        ] {
            let slot = try decoder.decode(
                DashboardSnapshotBriefing.self,
                from: payload(state: raw)
            )
            #expect(slot.briefingState == expected)
        }
    }

    @Test("Unknown briefingState raw maps to .unknown — no DecodingError")
    func unknownStateIsTolerated() throws {
        let slot = try decoder.decode(
            DashboardSnapshotBriefing.self,
            from: payload(state: "half-baked-v2")
        )
        #expect(slot.briefingState == .unknown("half-baked-v2"))
        // Unknown without content → deterministic fallback, never a spinner.
        #expect(slot.renderPolicy == .deterministicFallback)
    }

    @Test("Absent briefingStale decodes false (compat ≤v1.15.19)")
    func absentStaleDefaultsFalse() throws {
        let slot = try decoder.decode(
            DashboardSnapshotBriefing.self,
            from: payload(state: "ready", stale: nil)
        )
        #expect(slot.briefingStale == false)
    }

    @Test("briefingStale=true carries last text + timestamp → stale prose render")
    func staleCarriesTextAndTimestamp() throws {
        let slot = try decoder.decode(
            DashboardSnapshotBriefing.self,
            from: payload(
                briefing: Self.briefingJSON,
                state: "preparing",
                updatedAt: "\"2026-06-10T21:30:00.000Z\"",
                stale: "true"
            )
        )
        #expect(slot.briefingStale == true)
        #expect(slot.briefing?.paragraph.contains("124/82") == true)
        let expectedAsOf = ISO8601DateFormatter.fractional
            .date(from: "2026-06-10T21:30:00.000Z")
        guard case let .prose(briefing, asOf, stale) = slot.renderPolicy else {
            Issue.record("expected stale prose, got \(slot.renderPolicy)")
            return
        }
        #expect(briefing.paragraph.contains("124/82"))
        #expect(asOf == expectedAsOf)
        #expect(stale == true)
        #expect(slot.deliverableBriefing != nil)
    }

    @Test("no-provider without text → deterministic fallback, never preparing")
    func noProviderRendersDeterministicFallback() throws {
        let slot = try decoder.decode(
            DashboardSnapshotBriefing.self,
            from: payload(state: "no-provider", stale: "false")
        )
        #expect(slot.briefingState == .noProvider)
        #expect(slot.renderPolicy == .deterministicFallback)
        #expect(slot.renderPolicy != .preparing)
    }

    @Test("no-provider WITH stale text still renders the stale prose")
    func noProviderWithStaleTextRendersProse() throws {
        let slot = try decoder.decode(
            DashboardSnapshotBriefing.self,
            from: payload(
                briefing: Self.briefingJSON,
                state: "no-provider",
                updatedAt: "\"2026-06-09T05:12:00.000Z\"",
                stale: "true"
            )
        )
        guard case let .prose(_, asOf, stale) = slot.renderPolicy else {
            Issue.record("stale text must outrank no-provider, got \(slot.renderPolicy)")
            return
        }
        #expect(stale == true)
        #expect(asOf != nil)
    }

    @Test("Render policy: ready→fresh prose, preparing→preparing, disabled→hidden")
    func remainingPolicyArms() throws {
        let ready = try decoder.decode(
            DashboardSnapshotBriefing.self,
            from: payload(
                briefing: Self.briefingJSON,
                state: "ready",
                updatedAt: "\"2026-06-11T05:00:00.000Z\"",
                stale: "false"
            )
        )
        guard case let .prose(_, _, stale) = ready.renderPolicy else {
            Issue.record("ready+content must render prose")
            return
        }
        #expect(stale == false)

        let preparing = try decoder.decode(
            DashboardSnapshotBriefing.self,
            from: payload(state: "preparing", stale: "false")
        )
        #expect(preparing.renderPolicy == .preparing)

        let disabled = try decoder.decode(
            DashboardSnapshotBriefing.self,
            from: payload(state: "disabled")
        )
        #expect(disabled.renderPolicy == .hidden)
    }

    @Test("Unparseable briefing object degrades to nil — decode still succeeds")
    func malformedBriefingObjectTolerated() throws {
        // `briefing` is a server-free-form cache lift; a shape drift (e.g.
        // paragraph renamed) must degrade, not throw.
        let slot = try decoder.decode(
            DashboardSnapshotBriefing.self,
            from: payload(briefing: #"{"unexpected": ["shape"]}"#, state: "ready")
        )
        #expect(slot.briefing == nil)
        #expect(slot.renderPolicy == .deterministicFallback)
    }
}
