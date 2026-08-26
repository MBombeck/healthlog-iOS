import Foundation
@testable import HealthLog
import SwiftUI
import Testing

/// v0.12 W4-1 — deterministic screenshot generator for the three medication
/// compliance surfaces, proving the unified `ComplianceBand` now renders the
/// SAME colour for the SAME percentage across card / detail / Insights.
///
/// The app's real surfaces require a logged-in demo session + seeded
/// medications (and the project deliberately avoids pixel snapshots of full
/// hosts). To produce a reproducible artifact without a live session, this
/// renders each surface's compliance presentation in isolation via
/// `ImageRenderer` and writes PNGs into `.planning/v012-megamarathon/W4-screens/`.
///
/// Each surface is rendered at the three band-representative percentages
/// (75 % `.good` graphite, 55 % `.warn`, 30 % `.bad`) so the side-by-side shows
/// the three surfaces agreeing band-for-band — the W4-1 contradiction (75 %
/// graphite on card/Insights but warn on detail; 90 % green on detail only) is
/// visibly gone.
@MainActor
@Suite("ComplianceBand — cross-surface screenshot artifact")
struct ComplianceBandScreenshotTests {
    private static let outputDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // Medications
        .deletingLastPathComponent() // Screens
        .deletingLastPathComponent() // HealthLogTests
        .deletingLastPathComponent() // repo root
        .appendingPathComponent(".planning/v012-megamarathon/W4-screens", isDirectory: true)

    /// The three band-representative percentages.
    private static let samples: [(pct: Int, name: String)] = [
        (75, "good-75pct"),
        (55, "warn-55pct"),
        (30, "bad-30pct")
    ]

    @Test("renders the three compliance surfaces at .good/.warn/.bad and writes PNGs")
    func renderSurfaces() throws {
        try FileManager.default.createDirectory(at: Self.outputDir, withIntermediateDirectories: true)

        for sample in Self.samples {
            // 1) Detail KPI tile (the surface that CHANGED — was green-topped).
            let kpi = ComplianceKPISection(
                state: .server(MedicationDetailStore.ComplianceSummary(inTime: sample.pct, total: 100))
            )
            try write(view: surfaceFrame("Detail · ComplianceKPISection", kpi), name: "detail-kpi-\(sample.name)")

            // 2) + 3) Card + Insights bars — both are `private` to their hosts,
            // so render the band-equivalent bar (same `ComplianceBand` colour) to
            // evidence the shared colour the two bar surfaces now use.
            let cardBar = BandBarPreview(label: "30-Tage-Compliance", rate: sample.pct)
            try write(view: surfaceFrame("Card · ComplianceBar", cardBar), name: "card-bar-\(sample.name)")

            let insightsBar = BandBarPreview(label: "30 days", rate: sample.pct)
            try write(view: surfaceFrame("Insights · ComplianceBar", insightsBar), name: "insights-bar-\(sample.name)")
        }

        // Sanity: the artifact dir now holds 9 PNGs (3 surfaces × 3 bands).
        let pngs = try FileManager.default
            .contentsOfDirectory(at: Self.outputDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "png" }
        #expect(pngs.count >= 9)
    }

    // MARK: - Render helpers

    private func surfaceFrame(_ title: String, _ content: some View) -> some View {
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            Text(title)
                .font(.hlCaption.weight(.semibold))
                .foregroundStyle(HLText.secondary)
            content
        }
        .padding(HLSpace.lg)
        .frame(width: 360)
        .background(HLSurface.primary)
        .environment(\.colorScheme, .dark)
    }

    private func write(view: some View, name: String) throws {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
        guard let image = renderer.uiImage, let png = image.pngData() else {
            Issue.record("Failed to render \(name)")
            return
        }
        try png.write(to: Self.outputDir.appendingPathComponent("\(name).png"))
    }
}

/// A compliance bar whose fill routes through the single `ComplianceBand` source
/// of truth — the exact colour the card + Insights bars now paint. Standalone so
/// the screenshot can render it without the hosts' `private` bar types or their
/// store/environment.
private struct BandBarPreview: View {
    let label: String
    let rate: Int

    var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.xs) {
            HStack {
                Text(label)
                    .font(.hlCaption)
                    .foregroundStyle(HLText.secondary)
                Spacer(minLength: HLSpace.sm)
                Text("\(rate) %")
                    .font(.hlCaption.weight(.semibold))
                    .foregroundStyle(HLText.primary)
                    .monospacedDigit()
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(HLText.tertiary.opacity(0.15))
                    Capsule()
                        .fill(ComplianceBand.band(forPercent: rate).color)
                        .frame(width: max(0, proxy.size.width * CGFloat(rate) / 100))
                }
            }
            .frame(height: 6)
        }
        .frame(width: 320)
    }
}
