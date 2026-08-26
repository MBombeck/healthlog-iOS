import SwiftUI

/// #57 symmetry-sweep — the ONE canonical section label for the app-wide
/// (non-Insights) uppercase-tracked header role.
///
/// Before this, the dominant section-label pattern
/// (`.textCase(.uppercase).tracking(0.5)` + a `.semibold` font) was copy-pasted
/// ~40× across Medications / Mood / GLP1 / Coach / Charts / DoctorReport /
/// Achievements / Settings etc. with **four different fonts for the same role**
/// (`.hlSubhead` / `.hlFootnote` / `.hlCaption` / `.hlCaption2`). This unifies
/// the role onto ONE font so every section label reads identically
/// (PROJECT_GUIDE.md cross-screen-consistency check).
///
/// **Font for the role:** `.hlFootnote.weight(.semibold)`, uppercase,
/// `tracking(0.5)`. **Monochrome:** `HLText.secondary` — the dominant colour at
/// the migrated sites (44/45). Marked `.isHeader` for VoiceOver.
///
/// **Scope:** app-wide section labels. The Insights tab's SCREEN-level section
/// headers use their own sentence-case primitive (`InsightsSectionHeader`) —
/// do NOT replace those. Card-INTERNAL uppercase kickers/eyebrows (e.g. the
/// clinical-signals cards) route through `HLSectionLabel` everywhere,
/// including Insights (audit-01 C3 — the role was rendered in 4 sizes).
struct HLSectionLabel: View {
    private let text: Text

    init(_ title: LocalizedStringKey) {
        text = Text(title)
    }

    /// Verbatim init for already-localized, runtime-resolved labels (e.g. a
    /// `switch`-mapped category name). Avoids re-interpreting the resolved
    /// string as a localization key.
    init(verbatim title: String) {
        text = Text(verbatim: title)
    }

    var body: some View {
        text
            .font(.hlFootnote.weight(.semibold))
            .foregroundStyle(HLText.secondary)
            .textCase(.uppercase)
            .tracking(0.5)
            .accessibilityAddTraits(.isHeader)
    }
}
