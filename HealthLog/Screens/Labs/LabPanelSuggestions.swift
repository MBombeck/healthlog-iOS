import SwiftUI

/// The person's own panel names (`GET /api/biomarkers` `customPanels`,
/// server v1.47.1) as one-tap chips under the panel field of the marker
/// form. They narrow as the person types; a tap fills the field with the
/// server's spelling, so the same panel is never written two ways.
struct LabPanelSuggestionChips: View {
    let panels: [String]
    @Binding var text: String

    var body: some View {
        let shown = LabPanelSuggestions.matches(typed: text, panels: panels)
        if !shown.isEmpty {
            HLFlowLayout {
                ForEach(shown, id: \.self) { panel in
                    HLChip(verbatim: panel, isSelected: LabPanelSuggestions.same(text, panel)) { text = panel }
                        .accessibilityIdentifier("biomarker.editor.panelSuggestion")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("biomarker.editor.panelSuggestions"))
        }
    }
}

/// Which suggestions stand under the field. Pure.
enum LabPanelSuggestions {
    /// At most this many chips, so the form never turns into a wall.
    static let limit = 8

    /// Every panel while the field is empty; otherwise the ones containing
    /// what was typed, those starting with it first. A panel typed exactly
    /// stays, marked, so the person sees the match.
    static func matches(typed: String, panels: [String], limit: Int = limit) -> [String] {
        let needle = typed.trimmingCharacters(in: .whitespaces)
        var seen = Set<String>()
        let unique = panels.filter { seen.insert($0.lowercased()).inserted }
        guard !needle.isEmpty else { return Array(unique.prefix(limit)) }
        let hits = unique.filter { $0.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        let leading = hits.filter { $0.lowercased().hasPrefix(needle.lowercased()) }
        let inner = hits.filter { !$0.lowercased().hasPrefix(needle.lowercased()) }
        return Array((leading + inner).prefix(limit))
    }

    static func same(_ typed: String, _ panel: String) -> Bool {
        typed.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(panel) == .orderedSame
    }
}
