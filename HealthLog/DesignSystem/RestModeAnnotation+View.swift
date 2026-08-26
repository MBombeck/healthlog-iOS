import SwiftUI

/// **v1.18.3 — calm Rest Mode acknowledgement (annotate-never-mutate).**
///
/// A quiet, monochrome caption/pill rendered next to a server-derived surface
/// (Health Score, Recovery, Achievements/streaks) WHEN the server-authoritative
/// `RestModeAnnotation` is active AND the user has the illness module enabled.
///
/// **Doctrine.** Restrained per the app's monochrome design language + the
/// operator's "no prominent gamification / no alarming banners" feedback: a
/// soft "resting / recovering" acknowledgement, not a coloured alert. It frames
/// the number — it never changes it. The score, recovery composites and streaks
/// stay byte-identical; this view only sits beside them.
///
/// **Server authority.** iOS mirrors `restMode.active` verbatim — it never
/// recomputes Rest Mode. The Coach already softens its own nudges server-side,
/// so there is no client nudge-softening here; this view only acknowledges the
/// state on the screens that render score/recovery/streak context.
///
/// **Reduce-motion-safe:** static text + a system glyph, no animation.
struct RestModeAnnotationPill: View {
    /// The active annotation (callers pass `score.activeRestMode` — already
    /// gated on the server `active` flag).
    let restMode: RestModeAnnotation
    /// The phrasing variant for the host surface.
    var style: Style = .pill

    enum Style {
        /// Compact capsule for tile context (Dashboard Health Score).
        case pill
        /// Full-width quiet caption row for list/section context
        /// (Recovery, Achievements, Personal Records).
        case caption
    }

    var body: some View {
        switch style {
        case .pill:
            pill
        case .caption:
            caption
        }
    }

    private var pill: some View {
        HStack(spacing: HLSpace.xs) {
            Image(systemName: "leaf")
                .font(.system(.caption2, weight: .semibold))
                .accessibilityHidden(true)
            Text("illness.restMode.pill")
                .font(.hlCaption)
                .fontWeight(.medium)
                .lineLimit(1)
        }
        .foregroundStyle(HLText.secondary)
        .padding(.horizontal, HLSpace.sm)
        .padding(.vertical, HLSpace.xxs)
        .background(
            Capsule(style: .continuous)
                .fill(HLColor.surfaceElevated)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityIdentifier("illness.restMode.pill")
    }

    private var caption: some View {
        HStack(alignment: .firstTextBaseline, spacing: HLSpace.xs) {
            Image(systemName: "leaf")
                .font(.system(.caption2, weight: .semibold))
                .foregroundStyle(HLText.tertiary)
                .accessibilityHidden(true)
            Text("illness.restMode.caption")
                .font(.hlCaption)
                .foregroundStyle(HLText.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("illness.restMode.caption"))
        .accessibilityIdentifier("illness.restMode.caption")
    }

    private var accessibilityLabel: String {
        String(localized: "illness.restMode.pill.a11y")
    }
}

/// Render gate for the Rest Mode annotation: it shows ONLY when the server
/// flagged Rest Mode active AND the illness module is enabled for the user.
///
/// A `@ViewBuilder` host so call sites stay one-liners and the gate logic lives
/// in exactly one place (no scattered `if active && isEnabled` at each surface).
struct RestModeGate<Content: View>: View {
    /// Optional environment read so a host that omits `ModuleGate` (e.g. an
    /// isolated screen-snapshot test) renders nothing instead of crashing. In
    /// the live app the gate is always injected at the scene root; when absent
    /// we fail *closed* (no annotation) rather than guessing module state.
    @Environment(ModuleGate.self) private var moduleGate: ModuleGate?
    /// The score whose `activeRestMode` drives the gate. `nil` (no score loaded
    /// yet) → nothing renders.
    let score: HealthScore?
    @ViewBuilder let content: (RestModeAnnotation) -> Content

    var body: some View {
        if let restMode = score?.activeRestMode,
           moduleGate?.isEnabled(.illness) == true
        {
            content(restMode)
        }
    }
}
