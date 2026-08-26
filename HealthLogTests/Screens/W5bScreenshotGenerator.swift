import Foundation
@testable import HealthLog
import SwiftUI
import Testing

/// W5b screenshot generator — renders the two server-derived overview surfaces
/// (RhythmEvents card + derived re-frames block) with representative fixture
/// data via `ImageRenderer`, in light + dark, and writes PNGs to
/// `.planning/v012-megamarathon/W5b-screens/`.
///
/// **Why render-to-PNG instead of a live demo-tenant capture.** Both surfaces
/// self-suppress without data, and the demo tenant's rhythm-events / derived
/// envelopes are not guaranteed to be populated. Rendering the actual SwiftUI
/// cards with the exact fixture shapes the DTO decodes produces a deterministic
/// pixel artefact of the shipped surfaces (mono, no glass, disclaimer present).
@MainActor
@Suite("W5b screenshot generator")
struct W5bScreenshotGenerator {
    /// Sim-writable output dir. `#filePath` points at the host repo path but the
    /// sim sandbox cannot write there; an env override (`W5B_OUT`, set by the
    /// generator invocation) or the sim temp dir is used instead, and the test
    /// prints the absolute path so the host can copy the PNGs out.
    private var outDir: URL {
        if let override = ProcessInfo.processInfo.environment["W5B_OUT"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.temporaryDirectory.appendingPathComponent("W5b-screens", isDirectory: true)
    }

    private func write(_ view: some View, name: String, scheme: ColorScheme) {
        let host = view
            .frame(width: 393)
            .padding(HLSpace.lg)
            .background(scheme == .dark ? Color.black : Color(white: 0.96))
            .environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: host)
        renderer.scale = 3
        guard let image = renderer.uiImage, let data = image.pngData() else { return }
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let suffix = scheme == .dark ? "dark" : "light"
        try? data.write(to: outDir.appendingPathComponent("\(name)-\(suffix).png"))
    }

    private var rhythmEvents: [RhythmEventsDTO.Event] {
        let iso = ISO8601DateFormatter()
        return [
            .init(
                id: "1", type: "IRREGULAR_RHYTHM_NOTIFICATION", classification: "IRREGULAR",
                occurredAt: iso.date(from: "2026-06-01T08:30:00Z") ?? .now,
                source: "APPLE_HEALTH", deviceType: "Apple Watch"
            ),
            .init(
                id: "2", type: "WALKING_STEADINESS_EVENT", classification: "VERY_LOW",
                occurredAt: iso.date(from: "2026-05-28T14:05:00Z") ?? .now,
                source: "APPLE_HEALTH", deviceType: nil
            ),
            .init(
                id: "3", type: "BREATHING_DISTURBANCE_EVENT", classification: "FIRED",
                occurredAt: iso.date(from: "2026-05-20T03:10:00Z") ?? .now,
                source: "APPLE_HEALTH", deviceType: "Apple Watch"
            )
        ]
    }

    private func derived() -> [DerivedMetricDTO] {
        func env(_ metric: String, value: DerivedMetricDTO.Value, band: String, missing: [String] = []) -> DerivedMetricDTO {
            DerivedMetricDTO(
                metric: metric, status: "ok", value: value,
                coverage: .init(requiredInputs: 5, presentInputs: missing.isEmpty ? 5 : 4, historyDays: 28, missing: missing),
                confidence: .init(score: 80, band: band),
                provenance: .init(
                    inputs: ["RESTING_HEART_RATE", "HEART_RATE_VARIABILITY"],
                    source: "DAY", windowDays: 30, computedAt: .now
                ),
                reason: nil
            )
        }
        return [
            env("READINESS", value: .init(score: 78, band: "green"), band: "high", missing: ["RESPIRATORY_RATE"]),
            env("RECOVERY_SCORE", value: .init(score: 64, band: "yellow"), band: "medium"),
            env("STRESS_SCORE", value: .init(score: 42, band: "green"), band: "medium"),
            env("FITNESS_AGE", value: .init(score: nil, band: "high", fitnessAgeDeltaYears: -6, vo2Max: 44.2), band: "high"),
            env("HRV_BALANCE", value: .init(score: nil, band: "balanced"), band: "high")
        ]
    }

    @Test("generate W5b overview screenshots (rhythm + derived, light + dark)")
    func generate() {
        let stack = VStack(alignment: .leading, spacing: HLSpace.lg) {
            InsightsRhythmEventsCard(events: rhythmEvents)
            InsightsDerivedBlock(metrics: derived())
        }
        for scheme in [ColorScheme.light, .dark] {
            write(stack, name: "w5b-overview", scheme: scheme)
            write(InsightsRhythmEventsCard(events: rhythmEvents), name: "w5b-rhythm-events", scheme: scheme)
            write(InsightsDerivedBlock(metrics: derived()), name: "w5b-derived-block", scheme: scheme)
        }
        // Confirm at least the combined light shot landed; print the dir so the
        // host copies the PNGs to `.planning/v012-megamarathon/W5b-screens/`.
        let landed = FileManager.default.fileExists(
            atPath: outDir.appendingPathComponent("w5b-overview-light.png").path
        )
        print("W5B_SCREENS_DIR=\(outDir.path)")
        #expect(landed, "W5b screenshots written to \(outDir.path)")
    }
}
