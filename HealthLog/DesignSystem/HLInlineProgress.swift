import SwiftUI

/// The one spinner inside content: small, in the secondary ink, optionally
/// with a few words beside it.
///
/// A page that loads for the first time shows its skeleton
/// (``HLStateContainer``); a running action shows its spinner in the button
/// (`isLoading`). This is what stays: a part of a card that is still on its
/// way, the next page of a list.
struct HLInlineProgress: View {
    /// One size for every spinner in content.
    nonisolated static let controlSize: ControlSize = .small

    private let title: Text?

    init() {
        title = nil
    }

    init(_ title: LocalizedStringKey) {
        self.title = Text(title)
    }

    var body: some View {
        HStack(spacing: HLSpace.sm) {
            ProgressView()
                .controlSize(Self.controlSize)
                .tint(HLText.secondary)
            if let title {
                title
                    .font(.hlFootnote)
                    .foregroundStyle(HLText.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title ?? Text("Loading"))
    }
}
