import SwiftUI

/// Loading silhouette for ``TodayHeroCard`` — the same elevated card shell,
/// mirroring the Wave-2 stack: a full-width heading block ABOVE, then one row
/// pairing the top-signal line with the trailing 96 pt circular ring
/// placeholder, over a single rail-card placeholder. Mirrors the live hero's
/// boxes so the data-arrival is a cross-fade, not a layout jump. Uses the
/// design-system `HLSkeleton` shimmer (reduce-motion honoured at the token
/// layer) and is hidden from VoiceOver (the metric-tile skeleton below carries
/// the page's loading semantics).
struct TodayHeroSkeleton: View {
    var body: some View {
        HLCard(style: .elevated) {
            VStack(alignment: .leading, spacing: HLSpace.md) {
                // Heading — full width, two wrapped lines (Wave 2 / 2.1).
                VStack(alignment: .leading, spacing: HLSpace.sm) {
                    HLSkeleton(.capsule, width: 260, height: 18)
                    HLSkeleton(.capsule, width: 200, height: 18)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(alignment: .center, spacing: HLSpace.lg) {
                    HLSkeleton(.capsule, width: 160, height: 14)
                    Spacer(minLength: HLSpace.sm)
                    VStack(spacing: HLSpace.sm) {
                        HLSkeleton(.circle, width: 96, height: 96)
                        HLSkeleton(.capsule, width: 70, height: 14)
                    }
                }

                HLSkeleton(.capsule, width: 90, height: 10)
                RoundedRectangle(cornerRadius: HLRadius.card, style: .continuous)
                    .fill(HLSurface.secondary)
                    .frame(height: 84)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Localized copy (client-side keys only)

/// The hero's client-resolved copy. `title` / `body` on rail items arrive
/// already localized from the server; ONLY these `daily.today.*` and the action
/// `daily.action.*` label keys resolve here against the string catalog.
enum TodayHeroCopy {
    static var scoreLabel: String {
        local("daily.today.scoreLabel")
    }

    // Wave 2 / 2.2 — `deltaFlat`, `readFullBriefing` and `scoreDelta(_:)` were
    // DELETED together with the "-X gegenüber Ausgangswert" chip and the
    // "Vollständiges Briefing lesen" button (operator b227: the ring tap already
    // opens the same Insights overview, and the delta chip was noise). Their
    // `daily.today.delta*` / `daily.today.readFullBriefing` catalog entries were
    // retired with them.

    static var sleepPending: String {
        local("daily.today.sleepPending")
    }

    static var worthALook: String {
        local("daily.today.worthALook")
    }

    static var allClear: String {
        local("daily.today.allClear")
    }

    // 25-02 (E-2026-08-29 #2) — `provisionalA11y` was DELETED together with
    // the ring's null-score provisional face: with zero available inputs the
    // ring no longer renders at all, so there is no face left to speak. Its
    // `daily.today.provisional` catalog entry was retired with it.

    static var errorTitle: String {
        local("daily.today.error")
    }

    static var retry: String {
        local("daily.today.retry")
    }

    /// Reuses the app-wide "Dismiss" natural-language catalog key.
    static var dismiss: String {
        local("Dismiss")
    }

    static func ringLink(metric: String) -> String {
        localFormat("daily.today.ringLink", metric)
    }

    /// Resolve a server-sent action `labelKey` (`daily.action.*`) client-side.
    static func actionLabel(_ labelKey: String) -> String {
        local(labelKey)
    }

    // MARK: Resolution

    private static func local(_ key: String) -> String {
        String(localized: String.LocalizationValue(key))
    }

    private static func localFormat(_ key: String, _ argument: String) -> String {
        let template = String(localized: String.LocalizationValue(key))
        return String(format: template, argument)
    }
}
