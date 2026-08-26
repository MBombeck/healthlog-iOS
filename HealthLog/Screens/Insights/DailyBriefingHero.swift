import SwiftUI

/// Renders the server-generated `dailyBriefing` slot — paragraph + key
/// findings as horizontally scrollable chips. iOS displays the paragraph
/// **verbatim** (per `15-insights-architecture.md` — never paraphrase
/// or summarise server output).
public struct DailyBriefingHero: View {
    public let briefing: DailyBriefing
    public let style: Style
    /// v0.9.0 W2 — show the "on your device" provenance badge ONLY when the
    /// resolved briefing arm is genuinely the on-device FoundationModels
    /// output. Defaults `false` so the server / Statistik-Mode-floor arms
    /// never make a false privacy claim (RA2 §8 risk #6). The
    /// `OnDeviceBriefingHero` resolution ladder sets this to `true` solely on
    /// its `.onDevice(_)` branch.
    public let showsOnDeviceProvenance: Bool
    /// v0.10.0 W-Insights (R2 §6.1 Zone 1) — the three honest provenance
    /// states, made unmissable as a labeled row under the header in the `.full`
    /// style so the operator never wonders what is on-device. Defaults
    /// `.unspecified` (no row) for the compact Dashboard variant + any caller
    /// that hasn't opted in.
    public let provenance: Provenance
    /// v0.10.0 — whole-card tap action (opens the AskCoach conversation). nil →
    /// the card is not tappable. A trailing `ellipsis.message` glyph hints
    /// "ask more" when set.
    public let onTap: (() -> Void)?

    public enum Style {
        /// Compact dashboard variant — first sentence + 2 key-finding pills.
        case compact
        /// Full Insights-tab variant — full paragraph + scroll row of chips.
        case full
    }

    /// v0.10.0 W-Insights — provenance honesty, three states (R2 §6.1).
    public enum Provenance: Equatable, Sendable {
        /// On-device FoundationModels output.
        case onDevice
        /// Server-AI account briefing.
        case account
        /// Statistik-Mode floor — composed locally from the operator's data.
        case localData
        /// No provenance row (compact Dashboard variant / legacy callers).
        case unspecified

        var glyph: String? {
            switch self {
            case .onDevice: "lock.iphone"
            case .account: "icloud"
            case .localData: "chart.bar"
            case .unspecified: nil
            }
        }

        var label: String? {
            switch self {
            case .onDevice: String(localized: "On your device")
            case .account: String(localized: "From your account")
            case .localData: String(localized: "From your data")
            case .unspecified: nil
            }
        }
    }

    public init(
        briefing: DailyBriefing,
        style: Style = .full,
        showsOnDeviceProvenance: Bool = false,
        provenance: Provenance = .unspecified,
        onTap: (() -> Void)? = nil
    ) {
        self.briefing = briefing
        self.style = style
        self.showsOnDeviceProvenance = showsOnDeviceProvenance
        self.provenance = provenance
        self.onTap = onTap
    }

    public var body: some View {
        // v0.9.0 W2/W4 — monochrome doctrine (RA4 §2): the briefing stays on
        // the existing elevated `HLCard` surface. NO `.hlGlassEffect` on the
        // content card — glass on a text-heavy content surface violates
        // "content layer stays mono" and can hurt paragraph legibility.
        if let onTap {
            Button(action: onTap) { card }
                .hlPressable() // QOL-AUDIT H1: press feedback
                .accessibilityHint(Text(String(localized: "Double-tap to ask the coach")))
        } else {
            card
        }
    }

    private var card: some View {
        // v0.9.0 W2/W4 — monochrome doctrine (RA4 §2): the briefing stays on
        // the existing elevated `HLCard` surface. NO `.hlGlassEffect` on the
        // content card — glass on a text-heavy content surface violates
        // "content layer stays mono" and can hurt paragraph legibility.
        HLCard(style: .elevated) {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                HStack(spacing: HLSpace.xs) {
                    Image(systemName: "sun.max.fill")
                        .foregroundStyle(HLText.secondary)
                        // B1 (a11y) — decorative header glyph beside the
                        // "Today at a glance" caption. It carries no own
                        // information; without this VoiceOver announces the raw
                        // symbol name ("sun max fill") as noise before the label.
                        .accessibilityHidden(true)
                    Text("Today at a glance")
                        .font(.hlCaption.weight(.semibold))
                        .foregroundStyle(HLText.secondary)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 0)
                    // D3 (v0.10.0 Walkthrough-1) — calm the header. The hero
                    // carried TWO provenance signals (this badge + the labeled
                    // row below) plus an "ask more" glyph competing for the eye.
                    // The labeled provenance row is the single canonical signal
                    // in `.full`; the badge stays only for the `.unspecified`
                    // compact-Dashboard arm that has no row. The whole card is
                    // already tappable, so the glyph is redundant — dropped.
                    if provenance == .unspecified, showsOnDeviceProvenance {
                        HLBadge(String(localized: "On your device"), tone: .neutral)
                    }
                }

                if style == .full, let glyph = provenance.glyph, let label = provenance.label {
                    // R2 §6.1 — the unmissable, always-shown provenance row.
                    HStack(spacing: HLSpace.xs) {
                        Image(systemName: glyph)
                            .font(.hlCaption)
                            .foregroundStyle(HLText.tertiary)
                            // B1 (a11y) — the provenance glyph is decorative; the
                            // text label beside it carries the whole meaning. The
                            // row is `.combine`d, so an unhidden symbol name would
                            // leak into the merged element ("chart bar, From your
                            // data") — hide it so only the label speaks.
                            .accessibilityHidden(true)
                        Text(label)
                            .font(.hlCaption)
                            .foregroundStyle(HLText.tertiary)
                    }
                    .accessibilityElement(children: .combine)
                }

                // D3 — the paragraph is the "glance". In `.full` it is capped to
                // a few lines so it reads restful, not a wall of text; the whole
                // card opens the coach for the complete read. `.compact` already
                // shows only the first sentence.
                //
                // The server / on-device briefing copy carries inline Markdown
                // (`**bold**` emphasis). Rendered as a plain `Text(String)` the
                // `**` markers leaked on screen as literal characters. Route the
                // copy through the canonical `HLInsightProse.attributed(_:)` helper
                // so emphasis resolves and the `**` never reaches the screen —
                // while keeping the hero's own typography (`.hlBody`, primary
                // colour, leading alignment, capped line-limit) unchanged.
                Text(paragraphAttributed)
                    .font(.hlBody)
                    .foregroundStyle(HLText.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(style == .full ? 4 : nil)

                // I-3 ITEM 2 — the right-scrollable key-finding indicator chips
                // ("Puls liegt bei 240" …) read as overloaded on a mobile
                // overview. Per the redesign brief (§A3) the TEXT insight is the
                // glance; the chip strip + its `KeyFindingChip` view + the
                // `cleanFindings` helper were removed. The full key-finding set
                // still lives in the Coach conversation (whole-card tap) and the
                // Dynamics zone's notable-trend chips.

                // UI-Standard R15 (U1) — der pauschale `briefing.disclaimer`
                // („keine medizinische Beratung") ist ersatzlos entfallen. Er
                // lebt an genau zwei Orten: dem blockierenden Ack-Sheet beim
                // ersten Start und der Karte unter Einstellungen → Über diese
                // App. Die Provenienz-Zeile über dem Absatz sagt weiterhin,
                // woher der Text stammt — das ist Zuschreibung, kein Hinweis.
            }
        }
    }

    /// The paragraph copy with inline Markdown resolved to an `AttributedString`
    /// via the shared `HLInsightProse.attributed(_:)` parse contract, so
    /// server-sent `**bold**` renders as emphasis instead of leaking literal `**`.
    ///
    /// The Markdown is parsed on the WHOLE paragraph first, then (compact style)
    /// the first sentence is sliced from the resolved `AttributedString`. Slicing
    /// the raw string first — as the previous `firstSentence(String)` did — could
    /// cut through a `**bold**` span (e.g. `Dein **Puls.`), leaving an unbalanced
    /// marker that the Markdown parser echoes verbatim, re-leaking `**` on screen.
    /// Truncating the already-parsed attributed copy keeps emphasis balanced and
    /// guarantees no raw `**` ever reaches the surface. A parse failure falls back
    /// to the verbatim string inside `HLInsightProse.attributed(_:)` — no copy is
    /// ever dropped.
    private var paragraphAttributed: AttributedString {
        let full = HLInsightProse.attributed(briefing.paragraph)
        switch style {
        case .full:
            return full
        case .compact:
            return firstSentence(full)
        }
    }

    private func firstSentence(_ text: AttributedString) -> AttributedString {
        let characters = text.characters
        if let terminator = characters.firstIndex(where: { $0 == "." || $0 == "!" || $0 == "?" }) {
            return AttributedString(text[..<characters.index(after: terminator)])
        }
        return text
    }
}
