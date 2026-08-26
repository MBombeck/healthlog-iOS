import SwiftUI

/// Renders server-generated insight / assessment prose so it reads as flowing
/// text rather than a dense wall.
///
/// The server owns the copy (insights are server-generated — no client LLM), so
/// this view can't invent paragraph breaks that aren't in the source. What it
/// DOES do, on top of the previous plain `Text(string)`:
///   - interprets inline **Markdown** (emphasis, links) while PRESERVING the
///     source whitespace, so `\n\n` paragraph breaks + `**bold**` render instead
///     of showing literally or collapsing;
///   - adds `lineSpacing` so lines breathe;
///   - falls back to the raw string verbatim when the copy isn't valid Markdown.
///
/// If the server still emits the whole assessment as one unbroken block, the
/// remaining fix is server-side paragraph structuring (tracked in the insights
/// readability coordination issue) — this view makes the client render whatever
/// structure the copy carries as readably as possible.
struct HLInsightProse: View {
    let text: String
    var font: Font = .hlBody
    var color: Color = HLText.secondary

    /// `.inlineOnlyPreservingWhitespace` keeps every newline (so real paragraph
    /// gaps survive) while still resolving inline emphasis; a parse failure falls
    /// back to the plain string so no copy is ever dropped. Static + `nonisolated`
    /// so the parse contract is unit-testable without a view.
    nonisolated static func attributed(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    var body: some View {
        Text(Self.attributed(text))
            .font(font)
            .foregroundStyle(color)
            .lineSpacing(5)
            .fixedSize(horizontal: false, vertical: true)
    }
}
