import Foundation
@testable import HealthLog
import SwiftUI
import Testing
import WidgetKit

/// Draws every family of the measurement widget to PNG files for a person to
/// look at. It does nothing unless `TEST_RUNNER_HL_WIDGET_SHOTS` names an output
/// folder (outside the repository), so a normal run writes nothing.
@Suite("Measurement widget render check")
@MainActor
struct MeasurementWidgetRenderCheck {
    private struct Case {
        let name: String
        let family: WidgetFamily
        let size: CGSize
    }

    private static let cases: [Case] = [
        Case(name: "small", family: .systemSmall, size: CGSize(width: 170, height: 170)),
        Case(name: "medium", family: .systemMedium, size: CGSize(width: 364, height: 170)),
        Case(name: "large", family: .systemLarge, size: CGSize(width: 364, height: 382)),
        Case(name: "extraLarge", family: .systemExtraLarge, size: CGSize(width: 715, height: 330)),
        Case(name: "circular", family: .accessoryCircular, size: CGSize(width: 76, height: 76)),
        Case(name: "rectangular", family: .accessoryRectangular, size: CGSize(width: 172, height: 76)),
        Case(name: "inline", family: .accessoryInline, size: CGSize(width: 234, height: 26))
    ]

    private static func entries() -> [(String, LatestMeasurementEntry)] {
        let now = Date.now
        let latest = WidgetSnapshot.LatestMeasurement(
            kindRaw: "weight", title: "Gewicht", formattedValue: "72,4", unit: "kg",
            symbol: "scalemass", recordedAt: now.addingTimeInterval(-2 * 3600)
        )
        let values: [Double] = [73.4, 73.1, 73.2, 72.9, 72.8, 72.6, 72.7, 72.5, 72.4]
        let trend = values.enumerated().map { index, value in
            WidgetSnapshot.MetricGlance.TrendPoint(
                date: now.addingTimeInterval(Double(index - values.count) * 86400), value: value
            )
        }
        let glance = WidgetSnapshot.MetricGlance(
            kindRaw: "weight", title: "Gewicht", symbol: "scalemass", formattedValue: "72,4", unit: "kg",
            recordedAt: latest.recordedAt, trend: trend
        )
        let withTrend = WidgetSnapshot(
            nextDose: nil, compliance: .init(scheduled: 0, taken: 0),
            latestMeasurement: latest, metricGlances: [glance], generatedAt: now
        )
        let noTrend = WidgetSnapshot(
            nextDose: nil, compliance: .init(scheduled: 0, taken: 0), latestMeasurement: latest, generatedAt: now
        )
        func entry(_ snapshot: WidgetSnapshot, _ choice: String?, _ title: String?) -> LatestMeasurementEntry {
            LatestMeasurementEntry(
                date: now,
                resolved: WidgetMetricSelection.resolve(snapshot: snapshot, choice: choice),
                pickedTitle: title
            )
        }
        return [
            ("latest", entry(withTrend, nil, nil)),
            ("latest-notrend", entry(noTrend, nil, nil)),
            ("picked", entry(withTrend, "weight", "Gewicht")),
            ("empty", entry(noTrend, "pulse", "Puls"))
        ]
    }

    @Test("Renders every family to PNG when HL_WIDGET_SHOTS names a folder")
    func renderAll() throws {
        guard let folder = ProcessInfo.processInfo.environment["HL_WIDGET_SHOTS"], !folder.isEmpty else { return }
        let directory = URL(fileURLWithPath: folder, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var written = 0
        for (variant, entry) in Self.entries() {
            for item in Self.cases {
                for look in ["light", "dark", "tinted"] {
                    let isAccessory = [.accessoryCircular, .accessoryRectangular, .accessoryInline].contains(item.family)
                    let tint: WidgetTint = isAccessory ? .vibrant : (look == "tinted" ? .accented : .fullColor)
                    let scheme: ColorScheme = look == "light" ? .light : .dark
                    var content = AnyView(
                        LatestMeasurementWidgetView(entry: entry, familyOverride: item.family, tintOverride: tint)
                            .padding(isAccessory ? 0 : 16)
                            .frame(width: item.size.width, height: item.size.height)
                            .background(isAccessory ? Color.gray.opacity(0.35) : LAColor.surface)
                            .clipShape(RoundedRectangle(cornerRadius: isAccessory ? 12 : 22, style: .continuous))
                    )
                    if look == "tinted", !isAccessory {
                        // Stand-in for the system tint: one hue over a grey rendering.
                        content = AnyView(content.saturation(0).colorMultiply(Color(red: 1, green: 0.78, blue: 0.45)))
                    }
                    let renderer = ImageRenderer(content: content.environment(\.colorScheme, scheme))
                    renderer.scale = 2
                    let data = try #require(renderer.uiImage?.pngData())
                    try data.write(to: directory.appendingPathComponent("\(item.name)-\(look)-\(variant).png"))
                    written += 1
                }
            }
        }
        #expect(written == Self.entries().count * Self.cases.count * 3)
    }
}
