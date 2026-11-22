import SwiftUI

/// **"Kommende Zyklen"** (server v1.47.1, #164): the periods the server
/// projects after the next one, each as the window its first day may fall in.
/// The list and its bands are the server's (`/api/cycle/calendar`
/// `projection`); this card only renders them and never extrapolates. A late
/// period is stated in the muted tone: a fact about the calendar, not a
/// warning. Sits under the prediction card, which already names the next
/// period.
struct CycleUpcomingCard: View {
    let content: CycleUpcomingContent

    var body: some View {
        switch content {
        case .none:
            EmptyView()
        case .late:
            HLSectionHeader("cycle.upcoming.title", rank: .area)
            HLCard {
                Text("cycle.upcoming.late")
                    .hlText(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("cycle.upcoming.late")
            }
        case let .cycles(cycles):
            HLSectionHeader("cycle.upcoming.title", rank: .area)
            HLCard {
                VStack(alignment: .leading, spacing: HLSpace.md) {
                    HLFactGroup {
                        ForEach(cycles) { cycle in
                            HLFactRow(
                                label: Text(verbatim: Self.around(cycle)),
                                value: Text(verbatim: Self.window(cycle))
                            )
                            .accessibilityIdentifier("cycle.upcoming.row.\(cycle.k)")
                        }
                    }
                    Text("cycle.upcoming.footnote")
                        .hlText(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityIdentifier("cycle.upcoming")
        }
    }

    /// "Um den 12. Dez." — the most likely first day.
    static func around(_ cycle: CycleProjectedCycle) -> String {
        let date = CyclePredictionSummary.formatted(cycle.start) ?? cycle.start
        return String(localized: "cycle.upcoming.around \(date)")
    }

    /// "10. Dez. bis 15. Dez." — the band, as the prediction card writes one.
    static func window(_ cycle: CycleProjectedCycle) -> String {
        let low = CyclePredictionSummary.formatted(cycle.bandStart)
        let high = CyclePredictionSummary.formatted(cycle.bandEnd)
        guard let low, let high else { return low ?? high ?? "—" }
        guard low != high else { return low }
        return String(format: String(localized: "cycle.prediction.rangeFormat"), low, high)
    }
}
