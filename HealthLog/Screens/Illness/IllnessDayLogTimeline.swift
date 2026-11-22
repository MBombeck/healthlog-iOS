import SwiftUI

/// A compact day-log timeline for an episode detail: all logged days in one
/// card, one history row each (date, symptoms and note, fever as the value,
/// the impact as status). Pure render: every value is server-stored; nothing
/// is recomputed.
struct IllnessDayLogTimeline: View {
    let state: IllnessDayLogTimelineState
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            switch state {
            case .loading:
                HStack(spacing: HLSpace.sm) {
                    ProgressView().controlSize(.small)
                    Text("illness.daylog.timeline.loading")
                        .hlText(.emptyMessage)
                }
            case .error:
                HLCard(style: .outline) {
                    VStack(alignment: .leading, spacing: HLSpace.sm) {
                        Label("illness.daylog.timeline.error", systemImage: "exclamationmark.triangle")
                            .hlText(.emptyMessage)
                        HLButton("illness.daylog.timeline.retry", variant: .secondary) {
                            retry()
                        }
                    }
                }
            case .empty:
                // "Heute eintragen" stands right above; the detail
                // screen hides the timeline section while it is empty.
                EmptyView()
            case let .loaded(dayLogs):
                HLCard(layout: .rows) {
                    ForEach(dayLogs) { log in
                        IllnessDayLogRow(log: log)
                    }
                }
            }
        }
    }
}

struct IllnessDayLogRow: View {
    @Environment(\.unitPreferences) private var units
    let log: IllnessDayLogDTO

    var body: some View {
        let content = IllnessDayLogRowContent(log: log)
        HLRow(
            title: Text(verbatim: content.title),
            detail: content.detail.map { Text(verbatim: $0) },
            value: log.feverC.map { Text(verbatim: feverLabel($0)) },
            status: content.impact.map { HLRowStatus($0) }
        )
    }

    /// Canonical °C, shown in the account's unit.
    private func feverLabel(_ fever: Double) -> String {
        let value = HLValueFormat.number(units.displayValue(fever, kind: .bodyTemperature), fractionDigits: 0 ... 1)
        return String(localized: "illness.daylog.fever.value \(value) \(units.unitLabel(for: .bodyTemperature))")
    }
}
