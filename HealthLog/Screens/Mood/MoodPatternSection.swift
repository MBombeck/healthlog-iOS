import SwiftUI

/// v0.10.0 W-Mood-A — the gated correlation Pattern cards (DESIGN-B §5).
///
/// Renders the `MoodPattern` set the detector surfaced (each already
/// sample-gated + self-suppressed). The whole section is omitted when there
/// are no patterns — no empty card, the clinical-credibility guard. Collapsible
/// (`DisclosureGroup`); the expand state persists as a UI-pref in UserDefaults.
///
/// Color = signal only: icon / label / sentence are monochrome. The strength
/// label warms to `statusWarn` ONLY on a `strong` + adverse finding
/// (DESIGN-B §5.5) — the one place directional color is clinically justified,
/// at most one warmed label on the most robust adverse pattern.
///
/// D7 (Walkthrough-1): the old 3-dot strength meter read as an unclear "•••"
/// affordance — the operator couldn't tell what it was. Replaced with a plain,
/// self-explaining "Stark"/"Mittel" text label (the strength signal stays,
/// the ambiguity is gone).
struct MoodPatternSection: View {
    let patterns: [MoodPattern]

    // I-4 Item 4 — defaults COLLAPSED so the section no longer overwhelms the
    // page (the operator found the always-expanded patterns list hard to read).
    // The expand state still persists as a UI-pref once the operator opens it.
    @AppStorage("hl.mood.patterns.expanded") private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if patterns.isEmpty {
            EmptyView()
        } else {
            // v0.14.7 B7 — the "Was auffällt" title now lives as a heading ABOVE
            // the card (heading-above-card pattern, matching the Trend / metric
            // pages), not as an in-card title. The collapse affordance (chevron +
            // count) rides on the header row so the toggle behaviour is kept; the
            // card below holds only the pattern rows.
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                header
                if expanded {
                    HLCard {
                        VStack(alignment: .leading, spacing: HLSpace.lg) {
                            ForEach(patterns) { pattern in
                                card(pattern)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private var header: some View {
        Button {
            withAnimation(reduceMotion ? nil : HLMotion.spring) { expanded.toggle() }
        } label: {
            HStack(spacing: HLSpace.sm) {
                // I-4 Item 4 — "Muster" was suboptimal German; renamed to the
                // clearer "Was auffällt" / "What stands out" (the operator found
                // "Muster" hard to read as a section name). v0.14.7 B7 — the
                // title moved out of the card to this above-card heading; it now
                // uses the canonical `.hlHeadline` (InsightsSectionHeader parity)
                // instead of the in-card `.hlTitle3`.
                Text("What stands out")
                    .font(.hlHeadline)
                    .foregroundStyle(HLText.primary)
                // A quiet count so the collapsed state still signals there is
                // something inside without expanding (consistent with the
                // other pages' "N readings" affordance).
                Text("\(patterns.count)")
                    .font(.hlCaption.weight(.semibold))
                    .foregroundStyle(HLText.tertiary)
                    .monospacedDigit()
                    .accessibilityHidden(true)
                Spacer()
                Image(systemName: "chevron.down")
                    // swiftlint:disable:next dynamic_type_bypass
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(HLText.tertiary)
                    .rotationEffect(.degrees(expanded ? 0 : -90))
            }
            .contentShape(Rectangle())
            // Match the InsightsSectionHeader leading inset so the heading aligns
            // with the other above-card section titles on the page.
            .padding(.horizontal, HLSpace.xs)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("What stands out"))
        .accessibilityValue(Text(expanded ? "Expanded" : "Collapsed"))
        .accessibilityHint(Text("Double-tap to toggle"))
    }

    private func card(_ pattern: MoodPattern) -> some View {
        VStack(alignment: .leading, spacing: HLSpace.xs) {
            HStack(spacing: HLSpace.sm) {
                Image(systemName: pattern.icon)
                    // swiftlint:disable:next dynamic_type_bypass
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(HLText.secondary)
                    .frame(width: 20)
                HLSectionLabel(verbatim: Self.categoryLabel(pattern.kind))
                Spacer()
                strengthLabelChip(pattern)
            }
            Text(pattern.sentence)
                .font(.hlBody)
                .foregroundStyle(HLText.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(Self.categoryLabel(pattern.kind)))
        .accessibilityValue(Text("\(pattern.sentence) \(Self.strengthLabel(pattern.strength))"))
    }

    /// Plain strength label ("Stark"/"Mittel") in a recessed chip. Monochrome by
    /// default; warms to `statusWarn` ONLY on strong + adverse (the single earned
    /// accent — at most one warmed label, on the most robust adverse pattern).
    /// Replaces the old "•••" dot meter (D7 — operator couldn't read the dots).
    private func strengthLabelChip(_ pattern: MoodPattern) -> some View {
        let warmAdverse = pattern.strength == .strong && pattern.direction == .negative
        let tint = warmAdverse ? HLColor.statusWarn : HLText.secondary
        return Text(Self.strengthChipLabel(pattern.strength))
            .font(.hlCaption2.weight(.semibold))
            .foregroundStyle(tint)
            .textCase(.uppercase)
            .tracking(0.5)
            .padding(.horizontal, HLSpace.chip)
            .padding(.vertical, HLSpace.xxs)
            .background(
                RoundedRectangle(cornerRadius: HLRadius.xs, style: .continuous)
                    .fill(HLSurface.tertiary)
            )
            .accessibilityHidden(true)
    }

    // MARK: - Copy

    nonisolated static func categoryLabel(_ kind: MoodPattern.Kind) -> String {
        switch kind {
        case .previousDay: String(localized: "Day to day")
        case .weekend: String(localized: "Weekends")
        case .bestWeekday: String(localized: "Weekdays")
        case .tagPositive, .tagNegative: String(localized: "Activities")
        case .notePresence: String(localized: "Notes")
        case .laggedTag: String(localized: "Next day")
        case .multiEntry: String(localized: "Check-ins")
        }
    }

    /// Full strength label for VoiceOver ("Stärke: stark").
    nonisolated static func strengthLabel(_ strength: MoodPattern.Strength) -> String {
        switch strength {
        case .strong: String(localized: "Strength: strong")
        case .moderate: String(localized: "Strength: moderate")
        }
    }

    /// Short visible chip label ("Stark"/"Mittel") — D7, replaces the dot meter.
    nonisolated static func strengthChipLabel(_ strength: MoodPattern.Strength) -> String {
        switch strength {
        case .strong: String(localized: "Strong signal")
        case .moderate: String(localized: "Moderate signal")
        }
    }
}
