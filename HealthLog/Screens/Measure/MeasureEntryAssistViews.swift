import SwiftUI

/// The kinds the person logs by hand, as rows at the top of the capture sheet:
/// symbol, name, the last reading, and a check on the kind the form is on.
/// One tap switches the form, so the morning routine is a tap, not a menu
/// dive (#191 QoL, web "recent types as rows").
struct MeasureRecentKindRows: View {
    let kinds: [MetricKind]
    let lastReadings: [MetricKind: Measurement]
    @Binding var selection: MetricKind

    @Environment(\.unitPreferences) private var units

    var body: some View {
        ForEach(kinds) { kind in
            HLRowButton {
                selection = kind
            } label: {
                HLRow(
                    title: Text(verbatim: kind.displayName),
                    value: lastReadings[kind].map {
                        Text(verbatim: MeasureEntryWording.valueText($0.value, kind: kind, units: units))
                    },
                    accessory: kind == selection ? .symbol("checkmark") : .none
                ) {
                    HLRowGlyph(symbol: kind.descriptor.sfSymbol)
                }
            }
            .accessibilityAddTraits(kind == selection ? .isSelected : [])
            .accessibilityIdentifier("measure-sheet.recent-row.\(kind.rawValue)")
        }
    }
}

/// The line under the value field: the person's last reading of the kind
/// ("Zuletzt 72,4 kg, gestern") and, when the typed value is far from it, a
/// calm question to check it. Never blocks a save.
struct MeasureLastValueLine: View {
    let reading: Measurement
    let deviates: Bool

    @Environment(\.unitPreferences) private var units

    var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.xxs) {
            Text(verbatim: MeasureEntryWording.lastValue(reading, units: units))
                .hlText(.note)
                .accessibilityIdentifier("measure-sheet.last-value")
            if deviates {
                Label {
                    Text("measure.lastValueDeviates")
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                        .accessibilityHidden(true)
                }
                // Glyph beside the text, as `HLFormErrorText` stands, never
                // on a list's icon column.
                .labelStyle(.titleAndIcon)
                .hlText(.rowStatus, status: HLColor.statusWarn)
                .accessibilityIdentifier("measure-sheet.last-value.deviates")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
