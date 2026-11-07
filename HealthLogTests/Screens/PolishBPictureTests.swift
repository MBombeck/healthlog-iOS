// App-target views; the SPM test build skips the file.
#if !SWIFT_PACKAGE

    import Charts
    import Foundation
    @testable import HealthLog
    import SwiftUI
    import Testing
    import UIKit

    /// **POLISH-B pictures (rule 9).** Renders the surfaces this unit changed in
    /// the app host, light and dark, at the text sizes that matter, in the
    /// test language. Writes `<name>-<lang>.png` into `$POLISHB_RENDER_DIR`
    /// when set, never into the checkout.
    @MainActor
    @Suite("POLISH-B — pictures of the changed surfaces")
    struct PolishBPictureTests {
        // MARK: - B3, the date axis

        private static func chart(days: Int) -> some View {
            let end = Date(timeIntervalSince1970: 1_793_950_000)
            let points = (0 ..< days).map { offset in
                (date: end.addingTimeInterval(Double(offset - days) * 86400), value: 70 + Double(offset % 5))
            }
            return Chart(points, id: \.date) { point in
                LineMark(x: .value("Day", point.date), y: .value("Value", point.value))
            }
            .chartXAxis { ChartDateAxis.marks(for: points.map(\.date)) }
            .frame(height: 220)
            .padding(HLSpace.md)
        }

        @Test("B3: the date axis at regular, XXL and the accessibility sizes")
        func dateAxis() throws {
            let sizes: [(DynamicTypeSize, String)] = [
                (.large, "large"), (.xxLarge, "xxl"), (.accessibility3, "ax3"), (.accessibility5, "xxxl")
            ]
            for (size, label) in sizes {
                for days in [7, 30, 180] {
                    let view = Self.chart(days: days).environment(\.dynamicTypeSize, size)
                    _ = try Self.render(view, name: "b3-axis-\(days)d-\(label)", dark: false, height: 300)
                }
            }
            _ = try Self.render(
                Self.chart(days: 30).environment(\.dynamicTypeSize, .xxLarge),
                name: "b3-axis-30d-xxl-dark", dark: true, height: 300
            )
        }

        // MARK: - SHOTS: statistics, comparison line, records, at large text

        @Test("SHOTS F-AX-STATS / F-AX-DELTA: stats row and comparison line, regular and at the accessibility sizes")
        func statsAndDelta() throws {
            let stats = SeriesStats(mean: 128.4, min: 112, max: 141, stdDev: 6, count: 30)
            let view = VStack(alignment: .leading, spacing: HLSpace.md) {
                StatsRow(stats: stats, median: 129, unit: "mmHg")
                MetricRangeDelta(source: .server(delta: 0.8, unit: "%", sentiment: .neutral), range: .month)
                MetricRangeDelta(source: .ownComparison(Self.deltaPoints), range: .month)
            }
            .padding(HLSpace.md)
            for (size, label) in [(DynamicTypeSize.large, "large"), (.accessibility2, "ax2"), (.accessibility4, "ax4")] {
                _ = try Self.render(view.environment(\.dynamicTypeSize, size), name: "shots-stats-\(label)", dark: false, height: nil)
            }
            _ = try Self.render(
                view.environment(\.dynamicTypeSize, .accessibility4), name: "shots-stats-ax4-dark", dark: true, height: nil
            )
        }

        private static let deltaPoints: [SeriesPoint] = (0 ..< 30).map { day in
            SeriesPoint(
                id: "p\(day)",
                at: Date(timeIntervalSince1970: 1_793_950_000 + Double(day - 30) * 86400),
                value: day < 15 ? 80 : 80.6,
                secondary: nil
            )
        }

        @Test("SHOTS F-REC-1: record cards with a long name, floors and a new record")
        func recordCards() throws {
            func record(_ type: String, value: Double, unit: String, daysAgo: Double, kind: MetricKind?) -> PersonalRecord {
                let dto = PersonalRecordDTO(
                    id: "pictures.\(type)",
                    userId: "u1",
                    metricType: type,
                    metricSlot: nil,
                    direction: .max,
                    value: value,
                    unit: unit,
                    achievedAt: Date().addingTimeInterval(-86400 * daysAgo),
                    sourceMeasurementId: nil,
                    source: "HEALTHKIT",
                    externalId: nil,
                    createdAt: Date()
                )
                return PersonalRecord(
                    id: dto.id, base: dto, kind: kind, sparklineValues: [], peakIndex: nil,
                    previousValue: nil, bucket: .month, impressiveness: 0.5
                )
            }
            func grid(_ size: DynamicTypeSize) -> some View {
                LazyVGrid(columns: PersonalRecordsScreen.gridColumns(size), spacing: HLSpace.md) {
                    RecordCard(record: record("HRV", value: 68, unit: "ms", daysAgo: 60, kind: .hrv), onTap: { _ in })
                    RecordCard(record: record("FLIGHTS_CLIMBED", value: 27, unit: "floors", daysAgo: 5, kind: nil), onTap: { _ in })
                }
                .padding(HLSpace.md)
                .environment(\.dynamicTypeSize, size)
            }
            for dark in [false, true] {
                _ = try Self.render(grid(.large), name: "shots-records-\(dark ? "dark" : "light")", dark: dark, height: nil)
            }
            _ = try Self.render(grid(.accessibility3), name: "shots-records-ax3", dark: false, height: nil)
        }

        // MARK: - B8, mood card

        private static let moodInsights: MoodInsights = {
            var insights = MoodInsights(
                dailyAverages: [],
                latestScore: 4,
                mean: 3.6,
                avg30: 3.8,
                slope7: nil,
                slope30: 0.02,
                slope90: nil,
                avg30PriorPeriod: 3.4,
                tagDeltas: [],
                entryCount: 30,
                dayCount: 28
            )
            insights.trendDirection = .up
            return insights
        }()

        @Test("B8: the mood card without a verdict (as in 1.4) and with up-good")
        func moodCard() throws {
            for dark in [false, true] {
                let suffix = dark ? "dark" : "light"
                _ = try Self.render(
                    MoodHeroSummary(insights: Self.moodInsights).padding(HLSpace.md),
                    name: "b8-mood-noverdict-\(suffix)", dark: dark, height: nil
                )
                _ = try Self.render(
                    MoodHeroSummary(insights: Self.moodInsights, verdict: .upGood).padding(HLSpace.md),
                    name: "b8-mood-upgood-\(suffix)", dark: dark, height: nil
                )
            }
        }

        // MARK: - B10, the route card

        @Test("B10: the route card on v1.47.1, before and after a pass, and on an older server")
        func routeCard() async throws {
            func model(backfill: (@Sendable () async throws -> WorkoutRouteBackfillSummary)?) async throws
                -> WorkoutRoutesSettingModel
            {
                let defaults = try #require(UserDefaults(suiteName: "polish-b-pictures-\(UUID().uuidString)"))
                WorkoutRouteOptIn.set(true, ownerUserID: "user-pictures", defaults: defaults)
                let model = WorkoutRoutesSettingModel(
                    service: FakeRouteSettingService(server: true),
                    ownerUserID: "user-pictures",
                    defaults: defaults,
                    requestAuthorization: {},
                    backfill: backfill
                )
                await model.load()
                return model
            }
            let older = try await model(backfill: nil)
            let offered = try await model(backfill: { WorkoutRouteBackfillSummary(checked: 40, sent: 12, attached: 11) })
            let done = try await model(backfill: { WorkoutRouteBackfillSummary(checked: 40, sent: 12, attached: 11) })
            await done.runBackfill()
            let failed = try await model(backfill: { throw WorkoutRouteBackfillFailure.upload })
            await failed.runBackfill()
            for dark in [false, true] {
                let suffix = dark ? "dark" : "light"
                for (name, sut) in [("older", older), ("offered", offered), ("done", done), ("failed", failed)] {
                    _ = try Self.render(
                        WorkoutRoutesCard(model: sut).padding(HLSpace.md),
                        name: "b10-card-\(name)-\(suffix)", dark: dark, height: nil
                    )
                }
            }
            _ = try Self.render(
                WorkoutRoutesCard(model: done).padding(HLSpace.md).environment(\.dynamicTypeSize, .accessibility5),
                name: "b10-card-done-xxxl", dark: false, height: nil
            )
        }

        // MARK: - Rendering

        /// Renders `view` 393 pt wide at its own height (or `height`).
        static func render(_ view: some View, name: String, dark: Bool, height: CGFloat?) throws -> UIImage {
            let styled = view
                .environment(\.colorScheme, dark ? .dark : .light)
                .background(Color(uiColor: .systemBackground))
            let host = UIHostingController(rootView: AnyView(styled))
            host.overrideUserInterfaceStyle = dark ? .dark : .light
            host.safeAreaRegions = []
            let fitting = host.sizeThatFits(in: CGSize(width: 393, height: 4000))
            let size = CGSize(width: 393, height: height ?? max(1, ceil(fitting.height)))
            let window = UIWindow(frame: CGRect(origin: .zero, size: size))
            if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
                window.windowScene = scene
            }
            window.overrideUserInterfaceStyle = dark ? .dark : .light
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            window.isHidden = true
            if let dir = ProcessInfo.processInfo.environment["POLISHB_RENDER_DIR"] {
                let language = Bundle.main.preferredLocalizations.first ?? "base"
                try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                try image.pngData()?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name)-\(language).png"))
            }
            return image
        }
    }
#endif
