import SwiftUI

/// A form field with its label above it: a filled field still says what it
/// holds ("Trulicity" over "1,5 mg" read like two loose lines). The label is
/// the row subtitle role, the field keeps its own placeholder.
public struct HLFormField<Field: View>: View {
    private let label: LocalizedStringKey
    private let field: Field

    public init(_ label: LocalizedStringKey, @ViewBuilder field: () -> Field) {
        self.label = label
        self.field = field()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.xxs) {
            Text(label)
                .hlText(.rowSubtitle)
                // The field reads its own label; the line would say it twice.
                .accessibilityHidden(true)
            field
        }
    }
}
