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
    /// Two conditions, both load-bearing: the day curve belongs to the pulse
    /// page only (no other metric may fire the read), and it is pure server
    /// compute — in standalone / no-server there is nothing to fetch, so the
    /// block must not exist rather than sit there empty.
    nonisolated static func isAvailable(for kind: MetricKind, canShowCloudInsights: Bool) -> Bool {
        kind == .pulse && canShowCloudInsights
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
                    .padding(.vertical, HLSpace.lg)
                    .accessibilityIdentifier("insights.metric.pulse.intraday.loading")
            }
        }
        .task { await store.load(in: zone) }
    }

    // MARK: - Card

    private var card: some View {
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                header
                caption
                coverageNote
                content
            }
        }
        .accessibilityIdentifier("insights.metric.pulse.intraday")
    }

    private var header: some View {
        HStack(spacing: HLSpace.xs) {
            Text("insights.intraday.title")
                .font(.hlHeadline)
                .foregroundStyle(HLText.primary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: HLSpace.sm)
            navigator
        }
    }

    /// ‹ Tag › — 44 pt touch targets, "next" disabled on today.
    private var navigator: some View {
        HStack(spacing: 0) {
            Button {
                Task { await store.goToPreviousDay(in: zone) }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.hlFootnote.weight(.semibold))
                    .foregroundStyle(HLText.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("insights.intraday.previousDay"))
            .accessibilityIdentifier("insights.metric.pulse.intraday.previous")

            Text(dayLabel)
                .font(.hlCaption)
                .monospacedDigit()
                .foregroundStyle(HLText.secondary)
                .frame(minWidth: 56)
                .multilineTextAlignment(.center)

            Button {
                Task { await store.goToNextDay(in: zone) }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.hlFootnote.weight(.semibold))
                    .foregroundStyle(isOnToday ? HLText.tertiary : HLText.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isOnToday)
            .accessibilityLabel(Text("insights.intraday.nextDay"))
            .accessibilityIdentifier("insights.metric.pulse.intraday.next")
        }
    }

    /// Tension copy > hourly-grain note > the standard caption. Ordered exactly
    /// like the web (`intraday-pulse-chart.tsx:162-166`): the most specific
    /// honest statement about THIS day wins.
    private var caption: some View {
        Text(captionKey)
            .font(.hlCaption)
            .foregroundStyle(HLText.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var captionKey: LocalizedStringKey {
        guard let day = store.day else { return "insights.intraday.caption" }
        if let tension = day.tension {
            switch tension.part {
            case .morning: return "insights.intraday.tension.morning"
            case .afternoon: return "insights.intraday.tension.afternoon"
            case .evening: return "insights.intraday.tension.evening"
            case .night: return "insights.intraday.tension.night"
            case .unknown: return "insights.intraday.caption"
            }
        }
        // An older day was folded to hourly means — say so rather than imply
        // 10-minute detail the row no longer has.
        if day.grain == .hourly { return "insights.intraday.hourlyNote" }
        return "insights.intraday.caption"
    }

    /// "Based on N readings across M h" — shown ONLY when the day actually
    /// contains a break, so a contiguous day carries no needless caveat.
    @ViewBuilder
    private var coverageNote: some View {
        if let day = store.day,
           let coverage = IntradayPulseMath.coverage(day.series, bucketMinutes: day.bucketMinutes)
        {
            Group {
                if coverage.readingCount == 1 {
                    Text("insights.intraday.coverage.one \(coverage.hours)")
                } else {
                    Text("insights.intraday.coverage.many \(coverage.readingCount) \(coverage.hours)")
                }
            }
            .font(.hlCaption)
            .foregroundStyle(HLText.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("insights.metric.pulse.intraday.coverage")
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
                .frame(maxWidth: .infinity, minHeight: 180)
        } else if store.loadFailed {
            Button {
                Task { await store.refresh(in: zone) }
            } label: {
                Text("insights.intraday.loadFailed")
                    .font(.hlCaption)
                    .foregroundStyle(HLText.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("insights.metric.pulse.intraday.retry")
        } else {
            Text("insights.intraday.empty")
                .font(.hlCaption)
                .foregroundStyle(HLText.secondary)
                .frame(maxWidth: .infinity, minHeight: 120)
                .multilineTextAlignment(.center)
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
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }
}
