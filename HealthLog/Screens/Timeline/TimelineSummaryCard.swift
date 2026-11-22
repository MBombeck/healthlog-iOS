import SwiftUI

/// The chosen period under the board: its name ("Woche vom 16. November
/// 2026"), what happened in it and the mean of every line in it. Before a
/// day is picked, one line says how to pick one. VoiceOver steps from period
/// to period on the heading (swipe up or down).
struct TimelineSummaryCard: View {
    let store: TimelineStore
    let read: TimelineRead
    let wording: TimelineWording

    var body: some View {
        if let day = store.summaryDay {
            let summary = TimelineSummary.make(read: read, day: day, today: store.today, hidden: store.hiddenLanes)
            // The hint on how to pick a moment stands above the card until
            // one is picked, never at its foot under the floating period bar.
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                if store.selectedDay == nil {
                    Text("timeline.selection.hint")
                        .hlText(.note)
                }
                // Plain under the board, without a card: the period's name
                // and one line per value, so the board keeps the room.
                content(summary)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("timeline.summary")
                    .animation(.snappy(duration: 0.2), value: summary.from)
            }
        }
    }

    private func content(_ summary: TimelineSummary) -> some View {
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            heading(summary)
            if summary.isEmpty {
                Text("timeline.selection.empty")
                    .hlText(.emptyMessage)
            }
            if !summary.entries.isEmpty {
                HLFlowLayout(spacing: HLSpace.sm, lineSpacing: HLSpace.sm) {
                    ForEach(summary.entries) { entry in
                        TimelineEntryChip(entry: entry, wording: wording, today: store.today)
                    }
                }
            }
            values(summary)
                // Name and value stay within a reading width, never a
                // screen apart on a wide iPad.
                .frame(maxWidth: HLLayout.readableWidth, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func heading(_ summary: TimelineSummary) -> some View {
        Text(Self.title(from: summary.from, bucket: summary.bucket))
            .hlText(.cardTitle)
            .contentTransition(.numericText())
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("timeline.summary.title")
            .accessibilityHint(Text("timeline.selection.accessibilityHint"))
            .accessibilityAdjustableAction { direction in
                let step: Int = switch direction {
                case .increment: TimelineDay.bucketAfter(summary.from, summary.bucket)
                case .decrement: summary.from - 1
                @unknown default: summary.from
                }
                let window = store.window
                store.selectedDay = min(max(step, window.from), min(window.to, store.today))
            }
    }

    @ViewBuilder
    private func values(_ summary: TimelineSummary) -> some View {
        let means = summary.values.filter { store.isShown($0.key) }
        if !means.isEmpty || !summary.readings.isEmpty {
            VStack(spacing: 0) {
                ForEach(means) { value in
                    TimelineSummaryValueRow(
                        title: wording.title(forValue: value.key),
                        value: value.mean.map { wording.value($0, key: value.key) },
                        detail: value.mean == nil ? nil : Self.countText(value.count, symptom: value.key.hasPrefix("symptom:")),
                        color: TimelinePalette.color(forValue: value.key)
                    )
                }
                ForEach(summary.readings) { reading in
                    TimelineSummaryValueRow(
                        title: wording.title(forValue: reading.key),
                        value: wording.value(reading.point.value, key: reading.key),
                        detail: Self.readingDetail(reading.point),
                        color: TimelinePalette.color(forValue: reading.key)
                    )
                }
            }
        }
    }

    /// The period by name, in full.
    static func title(from start: Int, bucket: TimelineBucket) -> String {
        let date = TimelineDay.date(start)
        switch bucket {
        case .day:
            return HLDateFormat.date(date, style: .long)
        case .week:
            return String(localized: "timeline.selection.week \(HLDateFormat.date(date, style: .long))")
        case .month:
            return HLDateFormat.monthYear(date)
        case .quarter:
            let last = TimelineDay.date(TimelineDay.bucketAfter(start, .quarter) - 1)
            let first = HLDateFormat.month(date, abbreviated: false)
            return String(localized: "timeline.selection.range \(first) \(HLDateFormat.monthYear(last))")
        }
    }

    static func countText(_ count: Int, symptom: Bool) -> String {
        switch (symptom, count == 1) {
        case (true, true): String(localized: "timeline.symptoms.daysOne")
        case (true, false): String(localized: "timeline.symptoms.days \(count)")
        case (false, true): String(localized: "timeline.values.readingsOne")
        case (false, false): String(localized: "timeline.values.readings \(count)")
        }
    }

    static func readingDetail(_ point: TimelineLabPoint) -> String {
        let day = TimelineDay.number(point.date).map(TimelineAccessibility.day) ?? point.date
        switch point.rangeStatus {
        case .above: return String(localized: "timeline.labs.above \(day)")
        case .below: return String(localized: "timeline.labs.below \(day)")
        default: return day
        }
    }
}

/// One entry of the period as a chip: the lane's colour, the name and when.
struct TimelineEntryChip: View {
    let entry: TimelineSummary.Entry
    let wording: TimelineWording
    let today: Int

    var body: some View {
        HStack(spacing: HLSpace.chip) {
            Circle()
                .fill(TimelinePalette.color(forLane: entry.lane))
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(text)
                .hlText(.note)
                .lineLimit(2)
        }
        .padding(.horizontal, HLSpace.md)
        .padding(.vertical, HLSpace.chip)
        .background(HLSurface.secondary, in: Capsule())
        .accessibilityElement(children: .combine)
    }

    private var text: String {
        let item = entry.item
        let name = item.kind == .pause
            ? String(localized: "timeline.selection.paused \(item.label)")
            : wording.words(item)
        let start = TimelineDay.number(item.start).map(TimelineAccessibility.day) ?? item.start
        let when: String
        if item.open {
            when = String(localized: "timeline.selection.since \(start)")
        } else if let end = item.end, end != item.start {
            let last = TimelineDay.number(end).map(TimelineAccessibility.day) ?? end
            when = String(localized: "timeline.selection.range \(start) \(last)")
        } else {
            when = start
        }
        return "\(name), \(when)"
    }
}

/// One line's mean in the period: its colour, name, value and how many
/// readings stand behind it.
struct TimelineSummaryValueRow: View {
    let title: String
    let value: String?
    let detail: String?
    let color: Color

    var body: some View {
        // One line: name and how many readings stand behind the value on the
        // leading side, the value on the trailing side.
        HStack(alignment: .firstTextBaseline, spacing: HLSpace.sm) {
            Capsule()
                .fill(color)
                .frame(width: 10, height: 3)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                .accessibilityHidden(true)
            Text(title)
                .hlText(.factValue)
                .lineLimit(1)
                .layoutPriority(1)
            if let detail {
                Text(detail)
                    .hlText(.rowStatus)
                    .lineLimit(1)
            }
            Spacer(minLength: HLSpace.sm)
            Text(value ?? String(localized: "timeline.values.noValue"))
                .hlText(value == nil ? .rowStatus : .rowValue)
                .lineLimit(1)
                .layoutPriority(2)
        }
        .padding(.vertical, HLSpace.xxs)
        .accessibilityElement(children: .combine)
    }
}
