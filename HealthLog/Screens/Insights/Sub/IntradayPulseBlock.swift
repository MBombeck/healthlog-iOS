import SwiftUI

/// The pulse page's **day curve** block (P7, web `/insights/pulse` →
/// `IntradayPulseChart`, `pulse/page.tsx:163-166`).
///
/// One local day's 10-minute mean pulse with the personal resting reference and
/// a day navigator that pages backwards through prior days. Mounted ONLY by the
/// pulse metric page (`InsightsMetricScreen+Sections.intradayPulseBlock`), so
/// no other metric page ever fires the read.
///
/// **Fail-closed + calm.** A gated-off `insights` module, an older server
/// without the route, or a day with no readings all resolve to "nothing here":
/// on the FIRST load the whole block stays absent (never a dead card body —
/// the recovery-bug lesson). Once the operator has navigated INTO a past day
/// the shell stays put even when that day is empty, otherwise the navigator
/// would vanish and strand them there (web keeps the header for the same
/// reason).
///
/// **Wall-clock, not device time.** Bucket labels come straight from the
/// server's `startMinute`; only the `?date=` key and the navigator arithmetic
/// use the profile timezone (`SettingsStore.resolvedProfileTimeZone`).
struct IntradayPulseBlock: View {
    @Environment(IntradayPulseStore.self) private var store
    @Environment(SettingsStore.self) private var settingsStore

    private var zone: TimeZone {
        settingsStore.resolvedProfileTimeZone
    }

    /// The block's PLACEMENT gate, pulled out as pure logic so the wiring on
    /// `InsightsMetricScreen` is testable without a view host.
    ///
    /// The day curve belongs to the pulse page only (no other metric may fire
    /// the read).
    nonisolated static func isAvailable(for kind: MetricKind) -> Bool {
        kind == .pulse
    }

    var body: some View {
        Group {
            if store.hasContent || store.isPinnedToPastDay {
                card
            } else if !store.hasSettledOnce {
                // First load in flight — reserve nothing loud, just a calm
                // placeholder so the page does not jump when the day lands.
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, HLLayout.cardInset)
                    .accessibilityIdentifier("insights.metric.pulse.intraday.loading")
            }
        }
        .task { await store.load(in: zone) }
    }

    // MARK: - Card

    /// The card head carries the title; the day stepper opens the content.
    private var card: some View {
        HLCard("insights.intraday.title") {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                navigator
                caption
                content
                // 1.0.3 (App Review 1.4.1) — how the day's tension window is
                // derived from the personal band. At the card's foot, the same
                // place every other cited surface carries it.
                HLSourcesLink(topic: .healthStatus)
            }
        }
        .accessibilityIdentifier("insights.metric.pulse.intraday")
    }

    /// ‹ Tag › through the shared stepper, like the sleep night and
    /// movement; "next" is off on today.
    private var navigator: some View {
        HLStepperHeader(
            verbatim: dayLabel,
            previousLabel: "insights.intraday.previousDay",
            nextLabel: "insights.intraday.nextDay",
            canGoNext: !isOnToday,
            identifier: "insights.metric.pulse.intraday",
            previous: { Task { await store.goToPreviousDay(in: zone) } },
            next: { Task { await store.goToNextDay(in: zone) } }
        )
    }

    /// The card's one caption line, the most specific true statement about
    /// THIS day: tension copy > hourly-grain note > the coverage of a day with
    /// gaps > nothing. Ordered like the web (`intraday-pulse-chart.tsx:162-166`).
    /// The standing "averaged in 10-minute steps" caption moved into
    /// the page's info sheet; a day without anything special shows no line.
    @ViewBuilder
    private var caption: some View {
        if let day = store.day {
            if let tension = day.tension, let key = Self.tensionKey(tension.part) {
                captionText(key)
            } else if day.grain == .hourly {
                // An older day was folded to hourly means — say so rather than
                // imply 10-minute detail the row no longer has.
                captionText("insights.intraday.hourlyNote")
            } else if let coverage = IntradayPulseMath.coverage(day.series, bucketMinutes: day.bucketMinutes) {
                // "Based on N readings across M h" — only for a day with a
                // break, so a contiguous day carries no needless caveat.
                Group {
                    if coverage.readingCount == 1 {
                        Text("insights.intraday.coverage.one \(coverage.hours)")
                    } else {
                        Text("insights.intraday.coverage.many \(coverage.readingCount) \(coverage.hours)")
                    }
                }
                .hlText(.footnote)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("insights.metric.pulse.intraday.coverage")
            }
        }
    }

    private func captionText(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .hlText(.rowSubtitle)
            .fixedSize(horizontal: false, vertical: true)
    }

    private static func tensionKey(_ part: IntradayPulseDTO.PartOfDay) -> LocalizedStringKey? {
        switch part {
        case .morning: "insights.intraday.tension.morning"
        case .afternoon: "insights.intraday.tension.afternoon"
        case .evening: "insights.intraday.tension.evening"
        case .night: "insights.intraday.tension.night"
        case .unknown: nil
        }
    }

    /// Chart · retry line · empty-day line. The slot always resolves to
    /// SOMETHING once the shell is up, so the navigator never floats above a
    /// void.
    @ViewBuilder
    private var content: some View {
        if let day = store.day, day.hasContent {
            IntradayPulseChartView(day: day)
        } else if store.isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: HLChartStyle.heightRegular)
        } else if store.loadFailed {
            // A quiet link in the card, the app's one form of a text action.
            HLLinkButton("insights.intraday.loadFailed", systemImage: "arrow.clockwise", alignment: .leading) {
                Task { await store.refresh(in: zone) }
            }
            .accessibilityIdentifier("insights.metric.pulse.intraday.retry")
        } else {
            // A day without readings is missing data inside the card: one
            // quiet line where the curve would be.
            HLEmptyNote("insights.intraday.empty")
                .accessibilityIdentifier("insights.metric.pulse.intraday.empty")
        }
    }

    // MARK: - Labels

    private var isOnToday: Bool {
        store.isOnToday(in: zone)
    }

    /// "Heute" while tracking today, otherwise the short date of the pinned
    /// day. Parsed in the PROFILE zone so the label names the day the server
    /// answered for.
    private var dayLabel: String {
        if isOnToday { return String(localized: "insights.intraday.today") }
        let key = store.visibleDateKey(in: zone)
        guard let date = Self.keyParser(zone).date(from: key) else { return key }
        return HLDateFormat.dayMonth(date)
    }

    private static func keyParser(_ zone: TimeZone) -> DateFormatter {
        // Reads the store's `yyyy-MM-dd` key back into a date; nothing on
        // screen uses this formatter, the label goes through HLDateFormat.
        // swiftlint:disable:next hl_date_via_helper
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }
}
