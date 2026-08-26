import SwiftUI

/// **Phase C-explain — "Was passiert gerade mit meinem Körper".**
///
/// A warm, meets-you-where-you-are, deterministic per-phase explainer for the
/// CURRENT cycle phase. NOT AI: the phase + numbers come from the engine; this
/// view only chooses the right body of copy (de + en in `Localizable.xcstrings`)
/// and frames it with a tasteful, sparse warm-tint highlight.
///
/// **Graphic insertion point (next wave).** Each phase has a named asset slot —
/// `cycle.phase.<phase>.highlight` — where the next wave drops a generated
/// warm-organic illustration (via Gemini). Until that asset exists, a native
/// fallback motif (a soft warm radial gradient over the monochrome base) renders
/// in EXACTLY the same frame, so the layout is complete now and the generated
/// art swaps in with zero layout churn. See ``PhaseHighlightSlot``.
///
/// Monochrome doctrine: the body copy is monochrome `HLText`; the only colour is
/// the sparse warm phase tint in the highlight motif + the small phase chip.
struct CyclePhaseExplainer: View {
    let phase: CyclePhasePalette.Phase
    /// The 1-based day-of-cycle, surfaced in the chip ("Day N · Phase").
    let dayOfCycle: Int?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // v0.14.1 polish — framed as a TILE in `HLCard` (operator: the
        // menstruation graphic should be framed like the other cards). The
        // section title leads as a heading ABOVE the card; the warm headline +
        // body copy + the bottom-anchored highlight image live inside the card.
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            Text("cycle.explain.title")
                .font(.hlHeadline)
                .foregroundStyle(HLText.primary)
                .accessibilityAddTraits(.isHeader)
            HLCard {
                VStack(alignment: .leading, spacing: HLSpace.lg) {
                    PhaseHighlightSlot(phase: phase)
                        .frame(maxWidth: .infinity)
                        .frame(height: 120)
                        .clipShape(RoundedRectangle(cornerRadius: HLRadius.card, style: .continuous))
                        .overlay(alignment: .bottomLeading) { phaseChip }
                    Text(Self.headlineKey(for: phase))
                        .font(.hlHeadline)
                        .foregroundStyle(HLText.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(Self.bodyKey(for: phase))
                        .font(.hlBody)
                        .foregroundStyle(HLText.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var phaseChip: some View {
        let tint = CyclePhasePalette.tint(for: phase, scheme: colorScheme)
        return HStack(spacing: HLSpace.xs) {
            Circle().fill(tint).frame(width: 7, height: 7)
            Text(chipText)
                .font(.hlCaption.weight(.semibold))
                .foregroundStyle(HLText.primary)
        }
        .padding(.horizontal, HLSpace.sm)
        .padding(.vertical, HLSpace.xs)
        .hlGlassEffect(in: Capsule(), fallback: HLSurface.secondary)
        .padding(HLSpace.sm)
    }

    private var chipText: String {
        let phaseName = String(localized: Self.nameKey(for: phase))
        if let day = dayOfCycle {
            return String(
                format: String(localized: "cycle.explain.chip.dayPhase"),
                day, phaseName
            )
        }
        return phaseName
    }

    // MARK: - Deterministic per-phase copy keys (de + en)

    /// Phase name (chip + a11y).
    nonisolated static func nameKey(for phase: CyclePhasePalette.Phase) -> LocalizedStringResource {
        switch phase {
        case .menstrual: "cycle.phase.menstrual.name"
        case .follicular: "cycle.phase.follicular.name"
        case .ovulatory: "cycle.phase.ovulatory.name"
        case .luteal: "cycle.phase.luteal.name"
        }
    }

    /// Warm headline for the current phase.
    nonisolated static func headlineKey(for phase: CyclePhasePalette.Phase) -> LocalizedStringKey {
        switch phase {
        case .menstrual: "cycle.explain.menstrual.headline"
        case .follicular: "cycle.explain.follicular.headline"
        case .ovulatory: "cycle.explain.ovulatory.headline"
        case .luteal: "cycle.explain.luteal.headline"
        }
    }

    /// The warm, honest body of copy explaining what's happening right now.
    nonisolated static func bodyKey(for phase: CyclePhasePalette.Phase) -> LocalizedStringKey {
        switch phase {
        case .menstrual: "cycle.explain.menstrual.body"
        case .follicular: "cycle.explain.follicular.body"
        case .ovulatory: "cycle.explain.ovulatory.body"
        case .luteal: "cycle.explain.luteal.body"
        }
    }

    /// The named asset slot the next wave fills with a generated illustration.
    nonisolated static func highlightAssetName(for phase: CyclePhasePalette.Phase) -> String {
        switch phase {
        case .menstrual: "cycle.phase.menstrual.highlight"
        case .follicular: "cycle.phase.follicular.highlight"
        case .ovulatory: "cycle.phase.ovulatory.highlight"
        case .luteal: "cycle.phase.luteal.highlight"
        }
    }
}

// MARK: - Highlight slot (generated art slot + native fallback)

/// The per-phase illustration slot. Renders `Image(highlightAssetName)` when the
/// asset exists in the catalog (dropped in by the next wave); otherwise a native
/// warm-organic gradient motif fills the EXACT same frame so the layout never
/// shifts when the generated art lands.
///
/// **No layout churn contract:** both branches occupy the parent-supplied frame
/// identically; only the visual content swaps. Reduce-motion safe (fully static).
struct PhaseHighlightSlot: View {
    let phase: CyclePhasePalette.Phase

    @Environment(\.colorScheme) private var colorScheme

    /// v0.14.10 §4 — the part of a scaled-to-fill highlight image kept in frame.
    /// Default `.center`; the **menstrual** asset is black at the top + colour at
    /// the bottom, so it bottom-anchors to reveal the colourful lower portion (the
    /// other three phases stay centred/fill as before). Pure + `static` so it's
    /// trivially testable without a SwiftUI host.
    nonisolated static func contentAlignment(for phase: CyclePhasePalette.Phase) -> Alignment {
        switch phase {
        case .menstrual: .bottom
        case .follicular, .ovulatory, .luteal: .center
        }
    }

    var body: some View {
        let assetName = CyclePhaseExplainer.highlightAssetName(for: phase)
        // `UIImage(named:)` returns nil when the asset isn't in the catalog yet,
        // so we cleanly fall back without a broken-image placeholder.
        if UIImage(named: assetName) != nil {
            // v0.14.10 §4 — fill the slot, then anchor the overflow per phase: the
            // menstrual art is bottom-anchored (colour at the bottom) while the
            // others keep the centred fill. The frame + `.clipped()` crop the
            // scaled image to the slot at the chosen anchor.
            Color.clear
                .overlay(alignment: PhaseHighlightSlot.contentAlignment(for: phase)) {
                    Image(assetName)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                }
                .clipped()
                .accessibilityHidden(true)
        } else {
            nativeFallback
                .accessibilityHidden(true)
        }
    }

    /// A soft warm radial motif over the monochrome base — a few accent moments,
    /// not a redesign. The tint is the phase's warm tint; it sits low-chroma so
    /// it reads as a calm highlight, not candy.
    private var nativeFallback: some View {
        let tint = CyclePhasePalette.tint(for: phase, scheme: colorScheme)
        return ZStack {
            HLSurface.tertiary
            RadialGradient(
                colors: [tint.opacity(colorScheme == .dark ? 0.32 : 0.24), .clear],
                center: .init(x: 0.78, y: 0.28),
                startRadius: 4,
                endRadius: 180
            )
            RadialGradient(
                colors: [tint.opacity(colorScheme == .dark ? 0.16 : 0.12), .clear],
                center: .init(x: 0.2, y: 0.85),
                startRadius: 2,
                endRadius: 140
            )
        }
    }
}
