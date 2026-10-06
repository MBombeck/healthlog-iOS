// Uses app-target symbols (`HeroStrip`, `ChartDetailStore`) that the SPM
// library does not carry; the SPM test build skips the file.
#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import SwiftUI
    import Testing
    import UIKit

    // swiftlint:disable force_unwrapping

    /// **T4 / public #15 (TestFlight 290).** The reporter's Insights → Blutdruck
    /// "Letzte Messung" card drew "128/93 mmHg" as "12" / "8/9" / "3", with the
    /// unit beside the first fragment and the "↓ 3,3 mmHg" delta chip squeezing
    /// the row (German locale, large text).
    ///
    /// `HeroStrip`'s value had no line limit, so once value, unit and chip
    /// outgrew the row, SwiftUI broke the number. Following the project's
    /// pixel-snapshot-avoidance doctrine nothing here pins pixels: the strip is
    /// laid out by UIKit at phone width and its fitted HEIGHT is compared with
    /// the same strip showing a two-digit pulse. A one-line value costs the
    /// same height whatever its text, while every wrapped line of the number
    /// adds a large-title line.
    @MainActor
    @Suite("HeroStrip — a BP pair never breaks inside the number (T4, #15)", .serialized, .mockURLSession)
    struct HeroStripValueLayoutTests {
        /// iPhone 17 Pro width minus the Insights page gutters.
        private static let width: CGFloat = 402 - 2 * HLSpace.lg

        private func makeStore(kind: MetricKind, latest: MeasurementValue) throws -> ChartDetailStore {
            let env = AppEnvironment(
                baseURL: URL(string: "https://test.healthlog.local")!,
                bundleID: "dev.healthlog.app",
                appVersion: "1.1.0",
                buildNumber: "1"
            )
            let api = APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
            let store = try ChartDetailStore(
                kind: kind,
                measurementsRepo: MeasurementsRepository(api: api, outbox: OutboxQueue(inMemory: true)),
                insightsRepo: MetricInsightsRepository(api: api),
                resolveLocale: { "de" }
            )
            let at = Date(timeIntervalSince1970: 1_759_560_180) // Sun 4 Oct, 08:43
            store.latestRawMeasurement = Measurement(
                id: "srv-1", kind: kind, recordedAt: at, value: latest, source: .manual
            )
            // Four points → a prior-window delta, so the chip is on the row.
            let values: [Double] = [131, 133, 128, 128]
            store.series = MeasurementSeries(
                kind: kind,
                points: values.enumerated().map { index, value in
                    SeriesPoint(
                        id: "p\(index)",
                        at: at.addingTimeInterval(Double(index - 4) * 86400),
                        value: value,
                        secondary: kind == .bloodPressure ? 93 : nil
                    )
                },
                stats: SeriesStats(mean: 130, min: 128, max: 133, stdDev: 2, count: 4)
            )
            #expect(store.deltaVsPriorWindow != nil)
            return store
        }

        private func fittedHeight(_ store: ChartDetailStore, typeSize: DynamicTypeSize) -> CGFloat {
            let view = HeroStrip(store: store)
                .environment(\.locale, Locale(identifier: "de_DE"))
                .dynamicTypeSize(typeSize)
            let host = UIHostingController(rootView: view)
            return host.sizeThatFits(in: CGSize(width: Self.width, height: .greatestFiniteMagnitude)).height
        }

        @Test(
            "128/93 takes no more height than a two-digit value, de",
            arguments: [
                DynamicTypeSize.large, .xxxLarge, .accessibility1, .accessibility3, .accessibility5
            ]
        )
        func bloodPressureStaysOnOneLine(typeSize: DynamicTypeSize) throws {
            let bp = try makeStore(kind: .bloodPressure, latest: .bloodPressure(systolic: 128, diastolic: 93))
            let pulse = try makeStore(kind: .pulse, latest: .scalar(64))

            let bpHeight = fittedHeight(bp, typeSize: typeSize)
            let pulseHeight = fittedHeight(pulse, typeSize: typeSize)

            #expect(bpHeight > 0)
            // A wrapped number adds at least one large-title line (> 30 pt).
            #expect(
                bpHeight <= pulseHeight + 4,
                "BP hero is \(bpHeight) pt tall vs \(pulseHeight) pt for a pulse at \(typeSize)"
            )
        }

        @Test("the delta chip moves below the value from the accessibility sizes on")
        func chipStacksAtAccessibilitySizes() {
            #expect(!HeroStrip.stacksDeltaChip(.large))
            #expect(!HeroStrip.stacksDeltaChip(.xxxLarge))
            #expect(HeroStrip.stacksDeltaChip(.accessibility1))
            #expect(HeroStrip.stacksDeltaChip(.accessibility5))
        }
    }

#endif
