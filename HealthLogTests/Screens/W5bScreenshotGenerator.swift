import Foundation
@testable import HealthLog
import SwiftUI
import Testing

/// W5b screenshot generator — renders the RhythmEvents overview card with
/// representative fixture data via `ImageRenderer`, in light + dark, and writes
/// PNGs to `.planning/v012-megamarathon/W5b-screens/`.
///
/// 1.4 B4 — the derived re-frames block ("More from your data") it also
/// rendered was deleted; every derived score is a ring tile now.
///
/// **Why render-to-PNG instead of a live demo-tenant capture.** The card
/// self-suppresses without data, and the demo tenant's rhythm events are not
/// guaranteed to be populated. Rendering the actual SwiftUI card with the exact
/// fixture shapes the DTO decodes produces a deterministic pixel artefact of
/// the shipped surface (mono, no glass, disclaimer present).
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

    @Test("generate W5b overview screenshots (rhythm events, light + dark)")
    func generate() {
        let stack = VStack(alignment: .leading, spacing: HLSpace.lg) {
            InsightsRhythmEventsCard(events: rhythmEvents)
        }
        for scheme in [ColorScheme.light, .dark] {
            write(stack, name: "w5b-overview", scheme: scheme)
            write(InsightsRhythmEventsCard(events: rhythmEvents), name: "w5b-rhythm-events", scheme: scheme)
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
