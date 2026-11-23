import SwiftUI
import WidgetKit

// The measurement widget's views live in the shared folder so the app target
// can render them for the check that draws every family.

struct LatestMeasurementEntry: TimelineEntry {
    let date: Date
    let resolved: WidgetMetricSelection.Resolved
    /// The title of a picked metric that has no reading yet, for the empty line.
    let pickedTitle: String?

    var latest: WidgetSnapshot.LatestMeasurement? {
        resolved.reading
    }

    init(date: Date, latest: WidgetSnapshot.LatestMeasurement?) {
        self.init(
            date: date,
            resolved: WidgetMetricSelection.Resolved(reading: latest, trend: [], followsLatest: true),
            pickedTitle: nil
        )
    }

    init(date: Date, resolved: WidgetMetricSelection.Resolved, pickedTitle: String?) {
        self.date = date
        self.resolved = resolved
        self.pickedTitle = pickedTitle
    }
}

/// The title row every Home Screen widget starts with.
struct WidgetHeader: View {
    /// Steps with the tile: the small tiles keep the quiet caption, the wide
    /// ones read from further away.
    enum Size {
        case regular, medium, large

        var titleFont: Font {
            switch self {
            case .regular: .caption2.weight(.semibold)
            case .medium: .footnote.weight(.semibold)
            case .large: .title3.weight(.semibold)
            }
        }

        var iconFont: Font {
            switch self {
            case .regular: .caption2
            case .medium: .footnote
            case .large: .title3
            }
        }
    }

    let title: Text
    let symbol: String
    let surface: WidgetSurface
    var size: Size = .regular

    var body: some View {
        Label {
            title
                .font(size.titleFont)
                .foregroundStyle(size == .large ? LAColor.text : LAColor.textSecondary)
                .lineLimit(1)
        } icon: {
            Image(systemName: symbol)
                .font(size.iconFont)
                .foregroundStyle(LAColor.accent)
                .widgetLayer(.headerIcon, in: surface)
        }
        .labelStyle(.titleAndIcon)
    }
}

// MARK: - Views

struct LatestMeasurementWidgetView: View {
    @Environment(\.widgetFamily) private var environmentFamily
    @Environment(\.widgetRenderingMode) private var renderingMode
    @ScaledMetric(relativeTo: .largeTitle) private var extraLargeValueSize: CGFloat = 64
    let entry: LatestMeasurementEntry
    /// Set by the render check so every family can be drawn without a widget host.
    var familyOverride: WidgetFamily?
    var tintOverride: WidgetTint?

    init(entry: LatestMeasurementEntry, familyOverride: WidgetFamily? = nil, tintOverride: WidgetTint? = nil) {
        self.entry = entry
        self.familyOverride = familyOverride
        self.tintOverride = tintOverride
    }

    private var family: WidgetFamily {
        familyOverride ?? environmentFamily
    }

    private var tint: WidgetTint {
        tintOverride ?? WidgetTint(renderingMode)
    }

    private func drawsTrend(in trendFamily: WidgetMetricSelection.TrendFamily) -> Bool {
        WidgetMetricSelection.drawsTrend(in: trendFamily, resolved: entry.resolved)
    }

    var body: some View {
        switch family {
        case .accessoryInline:
            accessoryInline
        case .accessoryRectangular:
            accessoryRectangular
        case .accessoryCircular:
            accessoryCircular
        case .systemMedium:
            homeWide(large: false)
        case .systemExtraLarge:
            homeWide(large: true)
        case .systemLarge:
            homeLarge
        default:
            homeSmall
        }
    }

    // MARK: Home-screen

    private var homeSmall: some View {
        VStack(alignment: .leading, spacing: WidgetMetrics.stackSpacing) {
            header()
            Spacer(minLength: 0)
            if let latest = entry.latest {
                valueLine(latest)
                if drawsTrend(in: .small) {
                    WidgetSparkline(trend: entry.resolved.trend, tint: tint)
                        .frame(height: 26)
                }
                Text(relativeLine(latest))
                    .font(.caption2)
                    .foregroundStyle(LAColor.textSecondary)
                    .lineLimit(1)
            } else {
                emptyText(font: .subheadline, lines: 2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(deepLink)
    }

    /// The large tile (iPad home screen and iPhone): the same single reading as
    /// the small one, given the room. Nothing is added that the snapshot does
    /// not hold; the value just reads from across the table.
    private var homeLarge: some View {
        VStack(alignment: .leading, spacing: WidgetMetrics.stackSpacing) {
            header()
            Spacer(minLength: 0)
            if let latest = entry.latest {
                valueLine(latest, valueFont: .largeTitle.weight(.semibold), unitFont: .title3)
                Text(relativeLine(latest))
                    .font(.subheadline)
                    .foregroundStyle(LAColor.textSecondary)
                    .lineLimit(1)
                if drawsTrend(in: .large) {
                    trendBlock(minHeight: 90)
                }
            } else {
                emptyText(font: .headline, lines: 3)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(deepLink)
    }

    /// The medium and extra-large tiles: the reading on the left, its trend
    /// taking the rest of the width. Without a trend the extra-large tile
    /// centres the reading in its own arrangement instead of stretching the
    /// medium one across the iPad.
    @ViewBuilder
    private func homeWide(large: Bool) -> some View {
        let trendFamily: WidgetMetricSelection.TrendFamily = large ? .extraLarge : .medium
        if large, !(entry.latest != nil && drawsTrend(in: trendFamily)) {
            extraLargeCentered
        } else {
            HStack(alignment: .center, spacing: WidgetMetrics.columnSpacing) {
                VStack(alignment: .leading, spacing: WidgetMetrics.stackSpacing) {
                    header(size: large ? .large : .medium)
                    Spacer(minLength: 0)
                    if let latest = entry.latest {
                        valueLine(
                            latest,
                            valueFont: large ? extraLargeFont(size: extraLargeValueSize) : .largeTitle.weight(.semibold),
                            unitFont: large ? .title3 : .callout
                        )
                        Text(relativeLine(latest))
                            .font(large ? .subheadline : .caption)
                            .foregroundStyle(LAColor.textSecondary)
                            .lineLimit(1)
                    } else {
                        emptyText(font: .subheadline, lines: 3)
                    }
                }
                .frame(maxWidth: large ? 260 : .infinity, maxHeight: .infinity, alignment: .topLeading)
                if entry.latest != nil, drawsTrend(in: trendFamily) {
                    trendBlock(minHeight: 60)
                        .frame(maxWidth: .infinity)
                }
            }
            .widgetURL(deepLink)
        }
    }

    /// The extra-large tile without a trend: the title stays top left, the
    /// reading sits in the middle of the free area at the largest size.
    private var extraLargeCentered: some View {
        VStack(alignment: .leading, spacing: WidgetMetrics.stackSpacing) {
            header(size: .large)
            Spacer(minLength: 0)
            VStack(spacing: WidgetMetrics.stackSpacing) {
                if let latest = entry.latest {
                    valueLine(latest, valueFont: extraLargeFont(size: extraLargeValueSize * 1.25), unitFont: .title2)
                    Text(relativeLine(latest))
                        .font(.headline)
                        .foregroundStyle(LAColor.textSecondary)
                        .lineLimit(1)
                } else {
                    emptyText(font: .title3, lines: 2)
                }
            }
            .frame(maxWidth: .infinity)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(deepLink)
    }

    /// The iPad tile outgrows the largest text style. The size is a scaled
    /// metric, so it still follows the person's text size setting.
    private func extraLargeFont(size: CGFloat) -> Font {
        // swiftlint:disable:next dynamic_type_bypass
        .system(size: size, weight: .semibold)
    }

    /// The trend with the dates it spans under it.
    private func trendBlock(minHeight: CGFloat) -> some View {
        VStack(spacing: WidgetMetrics.lineSpacing) {
            WidgetSparkline(trend: entry.resolved.trend, tint: tint, lineWidth: 2.5)
                .frame(minHeight: minHeight)
            if let first = entry.resolved.trend.first, let last = entry.resolved.trend.last {
                HStack {
                    Text(first.date, format: .dateTime.day().month(.abbreviated))
                    Spacer(minLength: 0)
                    Text(last.date, format: .dateTime.day().month(.abbreviated))
                }
                .font(.caption2)
                .foregroundStyle(LAColor.textSecondary)
                .lineLimit(1)
            }
        }
        .privacySensitive()
    }

    /// "Noch kein Wert für Gewicht" for a picked metric without a reading, the
    /// old line otherwise.
    private func emptyText(font: Font, lines: Int) -> some View {
        Group {
            if let title = entry.pickedTitle {
                Text("widget.metric.empty \(title)")
            } else {
                Text("widget.latest_measurement.empty")
            }
        }
        .font(font)
        .foregroundStyle(LAColor.textSecondary)
        .lineLimit(lines)
    }

    private func header(size: WidgetHeader.Size = .regular) -> some View {
        WidgetHeader(
            title: Text(entry.latest?.title ?? entry.pickedTitle ?? String(localized: "widget.latest_measurement.header")),
            symbol: entry.latest?.symbol ?? "waveform.path.ecg",
            surface: .latestMeasurement,
            size: size
        )
    }

    private func valueLine(
        _ latest: WidgetSnapshot.LatestMeasurement,
        valueFont: Font = .title.weight(.semibold),
        unitFont: Font = .caption
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: WidgetMetrics.valueUnitSpacing) {
            Text(latest.formattedValue)
                .font(valueFont)
                .foregroundStyle(LAColor.text)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .widgetLayer(.primaryValue, in: .latestMeasurement)
            if !latest.unit.isEmpty {
                Text(latest.unit)
                    .font(unitFont)
                    .foregroundStyle(LAColor.textSecondary)
            }
        }
        .privacySensitive()
    }

    // MARK: Lock-Screen accessories

    private var accessoryRectangular: some View {
        HStack(spacing: WidgetMetrics.stackSpacing) {
            accessoryRectangularText
            if drawsTrend(in: .accessoryRectangular) {
                WidgetSparkline(trend: entry.resolved.trend, tint: tint, lineWidth: 1.5)
                    .frame(width: 46)
                    .privacySensitive()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetAccessibilityLabel(accessoryLabel)
    }

    private var accessoryRectangularText: some View {
        VStack(alignment: .leading, spacing: WidgetMetrics.lineSpacing) {
            if let latest = entry.latest {
                Label {
                    Text(latest.title).lineLimit(1)
                } icon: {
                    Image(systemName: latest.symbol)
                        .widgetLayer(.headerIcon, in: .latestMeasurement)
                }
                .font(.caption.weight(.semibold))
                Text(valueWithUnit(latest))
                    .font(.headline)
                    .lineLimit(1)
                    .widgetLayer(.primaryValue, in: .latestMeasurement)
                    // Lock-screen accessory: redact the measurement value when
                    // the device is locked (QA-b198 Sec-L-3 — PHI on lock).
                    .privacySensitive()
                Text(relativeLine(latest))
                    .font(.caption2)
                    .lineLimit(1)
            } else {
                Label {
                    Text("widget.latest_measurement.empty")
                } icon: {
                    Image(systemName: "waveform.path.ecg")
                }
                .font(.headline)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var accessoryCircular: some View {
        ZStack {
            AccessoryWidgetBackground()
            if let latest = entry.latest {
                VStack(spacing: 0) {
                    Image(systemName: latest.symbol)
                        .font(.caption2)
                        .widgetLayer(.headerIcon, in: .latestMeasurement)
                    Text(latest.formattedValue)
                        .font(.system(.callout, design: .rounded, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .widgetLayer(.primaryValue, in: .latestMeasurement)
                        // Redacted on the locked device like the other lock-screen accessories.
                        .privacySensitive()
                }
                .padding(4)
            } else {
                Image(systemName: "waveform.path.ecg")
            }
        }
        .widgetAccessibilityLabel(accessoryLabel)
    }

    private var accessoryInline: some View {
        Label {
            inlineText
        } icon: {
            Image(systemName: entry.latest?.symbol ?? "waveform.path.ecg")
        }
        // The inline string carries the measurement value — redact on lock
        // (QA-b198 Sec-L-3).
        .privacySensitive()
        .widgetAccessibilityLabel(accessoryLabel)
    }

    private var inlineText: Text {
        if let latest = entry.latest {
            Text("\(Text(latest.title)) \(Text(valueWithUnit(latest)))")
        } else {
            Text("widget.latest_measurement.empty")
        }
    }

    private var accessoryLabel: Text {
        if let latest = entry.latest {
            Text("\(Text(latest.title)): \(Text(valueWithUnit(latest)))")
        } else {
            Text("widget.latest_measurement.empty")
        }
    }

    // MARK: Copy helpers

    /// "72.4 kg" — value + unit, eliding an empty unit.
    private func valueWithUnit(_ latest: WidgetSnapshot.LatestMeasurement) -> String {
        latest.unit.isEmpty ? latest.formattedValue : "\(latest.formattedValue) \(latest.unit)"
    }

    /// "vor 2 Std." — relative time since the reading. Uses the system relative
    /// formatter so it localizes + abbreviates honestly. A stamp after now
    /// reads as now, never as a time still to come.
    private func relativeLine(_ latest: WidgetSnapshot.LatestMeasurement) -> String {
        latest.shownDate(now: .now).formatted(.relative(presentation: .named))
    }

    /// Deep link the whole-tile tap opens — the SPECIFIC metric page in the
    /// in-app Insights surface (`healthlog://insights/<kebab-slug>`), resolved
    /// from the snapshot reading's `kindRaw` via the canonical
    /// `InsightsLatestMeasurementDeepLink.url(forKindRaw:)`. Falls back to the
    /// Insights root when the kind has no Insights page (or there is no reading),
    /// so a tap never dead-ends or produces a broken URL.
    private var deepLink: URL? {
        InsightsLatestMeasurementDeepLink.url(forKindRaw: entry.latest?.kindRaw)
    }
}

private extension View {
    func widgetAccessibilityLabel(_ label: Text) -> some View {
        accessibilityElement().accessibilityLabel(label)
    }
}

/// The small daily trend of a measurement widget: a soft line through the
/// points and a dot on the newest one. Only the shape is drawn, never a number, so a
/// reading is always stated by the value text next to it.
struct WidgetSparkline: View {
    let trend: [WidgetSnapshot.MetricGlance.TrendPoint]
    let tint: WidgetTint
    var lineWidth: CGFloat = 2

    var body: some View {
        let points = WidgetMetricSelection.normalized(trend)
        GeometryReader { proxy in
            let inset = lineWidth + 2
            let mapped = points.map {
                CGPoint(
                    x: inset + $0.x * max(0, proxy.size.width - inset * 2),
                    y: inset + (1 - $0.y) * max(0, proxy.size.height - inset * 2)
                )
            }
            ZStack {
                Self.line(mapped)
                    .stroke(HLChartTints.seriesMid, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                if let last = mapped.last {
                    Circle()
                        .fill(HLChartTints.series)
                        .frame(width: lineWidth * 3, height: lineWidth * 3)
                        .position(last)
                }
            }
        }
        .widgetLayer(.trendLine, in: .latestMeasurement)
        .privacySensitive()
        .accessibilityElement()
        .accessibilityLabel(Text("widget.metric.trend.a11y \(trend.count)"))
    }

    /// A monotone cubic through the points (the shape Swift Charts calls
    /// `.monotone`): the line never runs above or below the two readings it
    /// connects, so it draws no swing the readings do not have.
    private static func line(_ points: [CGPoint]) -> Path {
        Path { path in
            guard let first = points.first else { return }
            path.move(to: first)
            for segment in WidgetMetricSelection.monotoneSegments(points.map { (x: Double($0.x), y: Double($0.y)) }) {
                path.addCurve(
                    to: CGPoint(x: segment.end.x, y: segment.end.y),
                    control1: CGPoint(x: segment.control1.x, y: segment.control1.y),
                    control2: CGPoint(x: segment.control2.x, y: segment.control2.y)
                )
            }
        }
    }
}
