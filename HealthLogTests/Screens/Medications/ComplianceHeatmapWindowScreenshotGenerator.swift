import Foundation
@testable import HealthLog
import SwiftUI
import Testing

/// **#13 render-verify generator.** Renders the compliance heatmap at the
/// 4-week and 26-week window picks plus the new Settings → Erscheinungsbild
/// picker row with representative fixture data via `ImageRenderer`, and
/// writes PNGs to `ISSUES1314_OUT` (default `/tmp/issues1314`). Mirrors the
/// committed `W5bScreenshotGenerator` pattern: both surfaces depend on live
/// store data in the app, so a deterministic fixture render is the honest
/// pixel artefact of the shipped layout (gate passed, mixed statuses,
/// adaptive 8 pt cells at 26 weeks).
@MainActor
@Suite("#13 compliance-heatmap window screenshot generator")
struct ComplianceHeatmapWindowScreenshotGenerator {
    private var outDir: URL {
        if let override = ProcessInfo.processInfo.environment["ISSUES1314_OUT"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return URL(fileURLWithPath: "/tmp/issues1314", isDirectory: true)
    }

    private func write(_ view: some View, name: String) {
        let host = view
            .frame(width: 393)
            .padding(HLSpace.lg)
            .background(Color.black)
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: host)
        renderer.scale = 3
        guard let image = renderer.uiImage, let data = image.pngData() else { return }
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        try? data.write(to: outDir.appendingPathComponent("\(name).png"))
    }

    /// 182 days of mixed-status fixture compliance (taken / partial / missed
    /// rhythm) so the grid shows all palette states and passes the 90-day
    /// tenure gate at every window pick.
    private func fixtureDays() -> [ComplianceDay] {
        var days: [ComplianceDay] = []
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        for offset in 0 ..< 182 {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            let scheduled = 2
            let taken = switch offset % 9 {
            case 0, 1, 2, 3, 4: 2 // taken (green)
            case 5, 6: 1 // partial (yellow)
            case 7: 0 // missed (red)
            default: 2
            }
            days.append(ComplianceDay(date: date, scheduled: scheduled, taken: taken))
        }
        return days
    }

    private func makeSettingsStore(weeks: ComplianceHeatmapWeeks) throws -> SettingsStore {
        let suite = "hl.tests.issues1314.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let store = SettingsStore(repo: SettingsRepository(api: StubAPIClient()), defaults: defaults)
        store.complianceHeatmapWeeks = weeks
        return store
    }

    @Test("generate #13 screenshots: heatmap @ 4 weeks, @ 26 weeks, settings row")
    func generateScreenshots() throws {
        let days = fixtureDays()
        for weeks in [ComplianceHeatmapWeeks.four, .twentySix] {
            let settings = try makeSettingsStore(weeks: weeks)
            let card = HLCard {
                ComplianceHeatmapSection(days: days)
            }
            .environment(settings)
            write(card, name: "heatmap-\(weeks.rawValue)w")
        }

        // The Personalization card hosting the new picker row — the REAL
        // shipped component (`SettingsPersonalizationCard`, extracted for
        // exactly this harness). Rendered standalone because ImageRenderer
        // cannot rasterise NavigationStack / scroll-hosted pages.
        let settings = try makeSettingsStore(weeks: .twelve)
        write(
            SettingsPersonalizationCard().environment(settings),
            name: "settings-appearance-row"
        )

        // The generator is a render harness, not an assertion suite — but a
        // zero-byte artefact means the renderer failed; surface that loudly.
        let files = (try? FileManager.default.contentsOfDirectory(atPath: outDir.path)) ?? []
        #expect(files.contains("heatmap-4w.png"))
        #expect(files.contains("heatmap-26w.png"))
        #expect(files.contains("settings-appearance-row.png"))
    }
}
