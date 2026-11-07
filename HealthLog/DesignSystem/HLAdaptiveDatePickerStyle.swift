import SwiftUI

/// POLISH-C (F-AX-DATEROW) — the app-wide date picker style, set once at the
/// root (`HealthLogApp`).
///
/// A compact `DatePicker` puts its label beside the date button. At an
/// accessibility text size the button keeps its width and the label is
/// squeezed into a column of single letters ("DOKUMENTDATUM",
/// "Ne-ue An-ga-ben gel-ten seit"). Here the label stands over the button at
/// those sizes; at every other size the picker is the plain compact one.
/// A picker that names its own style (graphical, wheel) keeps it.
struct HLAdaptiveDatePickerStyle: DatePickerStyle {
    func makeBody(configuration: Configuration) -> some View {
        AdaptiveDatePicker(configuration: configuration)
    }
}

private struct AdaptiveDatePicker: View {
    let configuration: DatePickerStyleConfiguration
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// A caller that hides the label (and draws its own beside the picker)
    /// keeps it hidden.
    @Environment(\.labelsVisibility) private var labelsVisibility

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize, labelsVisibility != .hidden {
            VStack(alignment: .leading, spacing: HLSpace.xs) {
                configuration.label
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                picker
                    .labelsHidden()
            }
        } else {
            picker
        }
    }

    /// The system compact picker with the same binding, range and parts.
    @ViewBuilder
    private var picker: some View {
        let components = configuration.displayedComponents
        switch (configuration.minimumDate, configuration.maximumDate) {
        case let (min?, max?):
            DatePicker(selection: configuration.$selection, in: min ... max, displayedComponents: components) { configuration.label }
                .datePickerStyle(.compact)
        case let (min?, nil):
            DatePicker(selection: configuration.$selection, in: min..., displayedComponents: components) { configuration.label }
                .datePickerStyle(.compact)
        case let (nil, max?):
            DatePicker(selection: configuration.$selection, in: ...max, displayedComponents: components) { configuration.label }
                .datePickerStyle(.compact)
        case (nil, nil):
            DatePicker(selection: configuration.$selection, displayedComponents: components) { configuration.label }
                .datePickerStyle(.compact)
        }
    }
}
