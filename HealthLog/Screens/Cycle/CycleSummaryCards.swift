import SwiftUI

// **Phase C5 — the calm summary cards under the cycle hero.**
//
// Prediction summary, cycle stats (avg length / variability / regularity), the
// "still learning" cold-start card, the disabled / unavailable card, and the
// calendar legend. All monochrome `HLText`; warm tints appear only as small
// legend dots (reusing `CyclePhasePalette`), keeping the doctrine sparse.

// MARK: - Prediction summary

struct CyclePredictionSummary: View {
    let prediction: CyclePredictionDTO?
    let today: String
    /// Confirmed-cycle maturity at the call site. Below
    /// ``CycleMaturity/minCyclesForFertility`` the fertile-window + ovulation
    /// rows are suppressed (App Store §1.4.1 / EU-MDR — no confident fertility
    /// claim from a population guess). The next-period row, the "still learning"
    /// caption + the b182 disclaimer always stay. Defaults to a mature value so
    /// existing non-gated call sites are unaffected; ``CycleScreen`` passes the
    /// real count.
    var cyclesObserved: Int = CycleMaturity.minCyclesForFertility

    var body: some View {
        if let prediction, !prediction.nextPeriodStart.isEmpty {
            // Suppress fertility claims while still learning, regardless of which
            // signal flagged it: the explicit confirmed-cycle count OR the
            // server/engine `stillLearning` flag (defaults true when absent).
            let showsFertility = Self.showsFertility(prediction, cyclesObserved: cyclesObserved)
            HLSettingsCard(icon: "calendar.badge.clock", title: "cycle.prediction.title") {
                VStack(alignment: .leading, spacing: HLSpace.md) {
                    row("cycle.prediction.nextPeriod", value: Self.range(prediction))
                    if showsFertility, let fertile = Self.fertile(prediction) {
                        row("cycle.prediction.fertileWindow", value: fertile)
                    }
                    if showsFertility, let ovulation = Self.formatted(prediction.predictedOvulation) {
                        row("cycle.prediction.ovulation", value: ovulation)
                    }
                    if prediction.stillLearning || !showsFertility {
                        Text("cycle.prediction.stillLearning")
                            .font(.hlCaption)
                            .foregroundStyle(HLText.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    // App Store §1.4.1 / EU MDR (b182 compliance fix): a
                    // fertility/ovulation prediction must carry a caveat. The old
                    // full-width block was dropped in 826a010d because it clipped
                    // the hero ring — but this caption lives INSIDE the prediction
                    // card, far below the ring, so it can't re-introduce that clip.
                    // Server-authoritative: render the verbatim server
                    // `prediction.disclaimer` when present, else the local
                    // fertility-specific fallback.
                    disclaimerCaption(prediction)
                }
            }
        }
    }

    /// The fertility-prediction caveat. Prefers the server-authoritative
    /// `prediction.disclaimer`; falls back to the local key when the server omits
    /// it (server ≤ contract without the field, or offline engine prediction).
    private func disclaimerCaption(_ prediction: CyclePredictionDTO) -> some View {
        Group {
            switch Self.disclaimerSource(prediction) {
            case let .server(text): Text(verbatim: text)
            case .localFallback: Text("cycle.prediction.disclaimer.local")
            }
        }
        .font(.hlCaption)
        .foregroundStyle(HLText.tertiary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, HLSpace.xs)
        .accessibilityIdentifier("cycle.prediction.disclaimer")
    }

    /// Which disclaimer text the prediction card paints. Server-authoritative when
    /// the server sends a non-blank `disclaimer`, else the local fertility caveat
    /// key. Pure + `static` so the App-Store §1.4.1 "fertility prediction always
    /// carries a caveat" contract is unit-testable without a SwiftUI host.
    enum DisclaimerSource: Equatable {
        case server(String)
        case localFallback
    }

    nonisolated static func disclaimerSource(_ prediction: CyclePredictionDTO) -> DisclaimerSource {
        let trimmed = prediction.disclaimer.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? .localFallback : .server(trimmed)
    }

    /// Whether the fertile-window + ovulation rows render. They are suppressed
    /// while the user is still learning — fewer than
    /// ``CycleMaturity/minCyclesForFertility`` confirmed cycles OR the prediction
    /// flagged `stillLearning` — so a population-prior guess is never painted as a
    /// concrete fertility claim (App Store §1.4.1 / EU-MDR). Pure + `static` so
    /// the suppression contract is unit-testable without a SwiftUI host.
    nonisolated static func showsFertility(
        _ prediction: CyclePredictionDTO,
        cyclesObserved: Int
    ) -> Bool {
        CycleMaturity.showsFertility(cyclesObserved: cyclesObserved, stillLearning: prediction.stillLearning)
    }

    private func row(_ key: LocalizedStringKey, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key).font(.hlSubhead).foregroundStyle(HLText.secondary)
            Spacer(minLength: HLSpace.sm)
            Text(verbatim: value)
                .font(.hlSubhead.weight(.medium))
                .foregroundStyle(HLText.primary)
                .multilineTextAlignment(.trailing)
        }
    }

    static func range(_ p: CyclePredictionDTO) -> String {
        let lo = formatted(p.nextPeriodStartLow)
        let hi = formatted(p.nextPeriodStartHigh)
        if let lo, let hi, lo != hi {
            return String(format: String(localized: "cycle.prediction.rangeFormat"), lo, hi)
        }
        return formatted(p.nextPeriodStart) ?? "—"
    }

    static func fertile(_ p: CyclePredictionDTO) -> String? {
        guard let lo = formatted(p.fertileWindowStart), let hi = formatted(p.fertileWindowEnd) else { return nil }
        return String(format: String(localized: "cycle.prediction.rangeFormat"), lo, hi)
    }

    static func formatted(_ key: String?) -> String? {
        guard let key, let date = dayFormatter.date(from: key) else { return nil }
        return mediumFormatter.string(from: date)
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let mediumFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = .current
        f.setLocalizedDateFormatFromTemplate("dMMM")
        return f
    }()
}

// MARK: - Cycle stats

struct CycleStatsCard: View {
    let stats: CycleStatsDTO?
    let cyclesObserved: Int

    var body: some View {
        HLSettingsCard(icon: "chart.bar", title: "cycle.stats.title") {
            VStack(alignment: .leading, spacing: HLSpace.md) {
                if let stats, cyclesObserved >= 2 {
                    if let avg = stats.avgLengthDays {
                        row("cycle.stats.avgLength", value: daysValue(avg))
                    }
                    if let variability = stats.lengthVariabilityDays {
                        row("cycle.stats.variability", value: daysValue(Int(variability.rounded())))
                    }
                    if let period = stats.avgPeriodLengthDays {
                        row("cycle.stats.avgPeriod", value: daysValue(period))
                    }
                    regularityRow(stats.regularityValue ?? .learning)
                } else {
                    Text("cycle.stats.learning")
                        .font(.hlBody)
                        .foregroundStyle(HLText.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func row(_ key: LocalizedStringKey, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key).font(.hlSubhead).foregroundStyle(HLText.secondary)
            Spacer(minLength: HLSpace.sm)
            Text(verbatim: value).font(.hlSubhead.weight(.medium)).foregroundStyle(HLText.primary)
        }
    }

    private func regularityRow(_ regularity: CycleRegularity) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("cycle.stats.regularity").font(.hlSubhead).foregroundStyle(HLText.secondary)
            Spacer(minLength: HLSpace.sm)
            Text(Self.regularityLabel(regularity))
                .font(.hlSubhead.weight(.medium))
                .foregroundStyle(HLText.primary)
        }
    }

    private func daysValue(_ days: Int) -> String {
        String(format: String(localized: "cycle.stats.daysFormat"), days)
    }

    static func regularityLabel(_ regularity: CycleRegularity) -> LocalizedStringKey {
        switch regularity {
        case .regular: "cycle.stats.regularity.regular"
        case .irregular: "cycle.stats.regularity.irregular"
        case .learning: "cycle.stats.regularity.learning"
        }
    }
}

// MARK: - Cold-start / learning hero fallback

struct CycleLearningCard: View {
    var body: some View {
        HLSettingsCard(icon: "sparkles", title: "cycle.learning.title", footer: "cycle.learning.footer") {
            Text("cycle.learning.body")
                .font(.hlBody)
                .foregroundStyle(HLText.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - No current assessment (Z1 / #72)

/// **Shown when the app holds no cycle verdict it may still put on screen.**
///
/// Two ways to get here: the device is offline and the last stored verdict has
/// outlived its own horizon (``CycleVerdictSnapshot/horizon``), or the server
/// predates v1.35.2 and publishes none. Deliberately NOT ``CycleLearningCard``:
/// "still learning" is a claim about the data, and the data may be perfectly
/// complete — what is missing is a current answer, and the ring will not invent
/// one on a device that does not know which day it is in the profile's timezone.
struct CycleVerdictUnavailableCard: View {
    var body: some View {
        HLSettingsCard(icon: "wifi.slash", title: "cycle.verdict.unavailable.title") {
            Text("cycle.verdict.unavailable.body")
                .font(.hlBody)
                .foregroundStyle(HLText.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier("cycle.home.verdictUnavailable")
    }
}

// MARK: - Disabled / unavailable

struct CycleUnavailableCard: View {
    var body: some View {
        HLSettingsCard(icon: "lock", title: "cycle.unavailable.title") {
            Text("cycle.unavailable.body")
                .font(.hlBody)
                .foregroundStyle(HLText.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, HLSpace.lg)
        .padding(.top, HLSpace.lg)
    }
}

// MARK: - Calendar legend

struct CycleCalendarLegend: View {
    /// When true (still learning, `< CycleMaturity.minCyclesForFertility`
    /// confirmed cycles) the calendar does NOT paint fertile/ovulation markers,
    /// so the legend must not advertise them either. Defaults to `false` so
    /// unrelated call sites keep the full key.
    var suppressFertility: Bool = false

    @Environment(\.colorScheme) private var colorScheme

    /// Every distinct marker the calendar can draw gets ITS OWN entry, and each
    /// swatch is the SAME shape/colour/dash the calendar paints (reusing
    /// `CycleMarkerSwatch`), so the legend is a true key — not a generic dot list.
    /// While still learning the fertile + ovulation entries are dropped to match
    /// the suppressed calendar markers.
    private var entries: [(swatch: CycleMarkerSwatch.Kind, key: LocalizedStringKey)] {
        var items: [(swatch: CycleMarkerSwatch.Kind, key: LocalizedStringKey)] = [
            (.periodLogged, "cycle.legend.period"),
            (.predictedPeriod, "cycle.legend.predictedPeriod")
        ]
        if !suppressFertility {
            items.append((.fertile, "cycle.legend.fertile"))
            items.append((.ovulation, "cycle.legend.ovulation"))
        }
        items.append((.symptoms, "cycle.legend.symptoms"))
        items.append((.today, "cycle.legend.today"))
        return items
    }

    var body: some View {
        // Two tidy rows of three: never wraps awkwardly, every marker explained.
        let columns = Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3)
        LazyVGrid(columns: columns, alignment: .leading, spacing: HLSpace.sm) {
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                legendItem(kind: entry.swatch, key: entry.key)
            }
        }
        .padding(.top, HLSpace.xs)
        .accessibilityElement(children: .combine)
    }

    private func legendItem(kind: CycleMarkerSwatch.Kind, key: LocalizedStringKey) -> some View {
        HStack(spacing: HLSpace.xs) {
            CycleMarkerSwatch(kind: kind, scheme: colorScheme)
                .frame(width: 16, height: 16)
            Text(key)
                .font(.hlCaption)
                .foregroundStyle(HLText.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }
}
