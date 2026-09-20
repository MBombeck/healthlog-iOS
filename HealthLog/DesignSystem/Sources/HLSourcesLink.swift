import SwiftUI

/// **1.0.3 (App Review 1.4.1) — the citation affordance.**
///
/// One calm caption control ("Sources" + `text.book.closed`) under a medical
/// statement. Tapping opens ``HLSourcesSheet`` for the topic. Fail-closed like
/// ``HLLearnMoreLink``: a topic with neither references nor a methodology text
/// renders nothing, so a surface can never show a dead "Sources" button.
struct HLSourcesLink: View {
    enum Style {
        case caption
        /// **1.4.1** — the citation IS the caption. A status card's guideline
        /// name ("ESH 2023", "WHO 2000") already states the authority a
        /// classification rests on, so it becomes the control itself rather than
        /// growing a second "Sources" row underneath saying the same thing. The
        /// text is already localized by the caller (it comes from a catalog key
        /// the caller owns), hence `String` and `Text(verbatim:)`.
        case captionText(String)
    }

    let topic: MedicalSourceTopic
    var style: Style = .caption

    @State private var isPresented = false

    nonisolated static func isRenderable(_ topic: MedicalSourceTopic) -> Bool {
        !MedicalSourceCatalog.sources(for: topic).isEmpty
            || !MedicalSourceCatalog.dynamicSources(for: topic).isEmpty
            || MedicalSourceCatalog.methodologyKey(for: topic) != nil
    }

    nonisolated static func identifier(for topic: MedicalSourceTopic) -> String {
        "sources.\(topic.accessibilitySuffix)"
    }

    var body: some View {
        if Self.isRenderable(topic) {
            Button {
                isPresented = true
            } label: {
                switch style {
                case .caption:
                    HStack(spacing: HLSpace.xxs) {
                        Image(systemName: "text.book.closed")
                            .font(.hlCaption2)
                            .accessibilityHidden(true)
                        Text("sources.link.label")
                    }
                    .font(.hlCaption)
                    .foregroundStyle(HLText.secondary)
                    .frame(minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                case let .captionText(text):
                    HStack(spacing: HLSpace.xxs) {
                        Text(verbatim: text)
                        Image(systemName: "text.book.closed")
                            .font(.hlCaption2)
                            .accessibilityHidden(true)
                    }
                    .font(.hlCaption)
                    .foregroundStyle(HLText.tertiary)
                    .frame(minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("sources.link.a11y"))
            .accessibilityIdentifier(Self.identifier(for: topic))
            .sheet(isPresented: $isPresented) {
                HLSourcesSheet(topic: topic)
            }
        }
    }
}
