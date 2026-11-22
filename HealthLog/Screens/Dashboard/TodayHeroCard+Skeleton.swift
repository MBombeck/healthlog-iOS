import SwiftUI

/// Loading silhouette for ``TodayHeroHost``: the live hero card itself,
/// drawn from a placeholder digest and redacted (a lead of three lines, three
/// fact pairs, the ring as a shimmer circle with its word and one footnote),
/// and under it one hint in the place the "worth a look" section takes. Built
/// from the live views, the skeleton has the loaded card's height at every
/// text size, so the arrival of the data is a cross-fade instead of a jump.
/// Hidden from VoiceOver (the metric-tile skeleton below carries the page's
/// loading semantics).
struct TodayHeroSkeleton: View {
    /// The loaded card's short-window form, so the skeleton has its height.
    var isShortWindow = false

    var body: some View {
        VStack(alignment: .leading, spacing: HLLayout.cardGap) {
            Self.heroCard(isShortWindow: isShortWindow)
            Self.hint
        }
        .accessibilityHidden(true)
    }

    /// The hero card's silhouette on its own.
    static var heroCard: some View {
        heroCard(isShortWindow: false)
    }

    /// The hero card's silhouette in a short or a tall window.
    static func heroCard(isShortWindow: Bool) -> some View {
        TodayHeroCard(digest: placeholderDigest, onRingTap: {}, isPlaceholder: true, isShortWindow: isShortWindow)
            .redacted(reason: .placeholder)
            .allowsHitTesting(false)
    }

    /// Placeholder text of typical length; redacted, it is never read. The
    /// lead is long enough to fill the three lines a lead may take.
    static let placeholderDigest = DailyDigest(
        generatedAt: "",
        phase: "final",
        sleepPending: false,
        score: DailyDigest.Score(value: 0, band: "", delta: nil, steadyWeeks: 5),
        topSignal: nil,
        briefingLead: nil,
        line: "Placeholder lead of the day that runs long enough to wrap over three full lines of the card, "
            + "like the sentence the server sends on most mornings.",
        worthALook: [],
        today: [
            DailyDigest.TodayFact(kind: "medication", label: "Placeholder", value: "Placeholder value", href: nil, moduleKey: nil),
            DailyDigest.TodayFact(kind: "sleep", label: "Placeholder", value: "Placeholder value", href: nil, moduleKey: nil),
            DailyDigest.TodayFact(kind: "vitals", label: "Placeholder", value: "Placeholder value", href: nil, moduleKey: nil)
        ]
    )

    /// One hint with a one-line title and a one-line text, drawn by the live
    /// section itself and redacted, so it has the height of the real hint at
    /// every text size.
    static var hint: some View {
        TodayHeroWorthALookSection(
            items: [placeholderHint],
            onAction: { _, _ in },
            onDismiss: { _ in }
        )
        .redacted(reason: .placeholder)
        .allowsHitTesting(false)
    }

    /// Placeholder text of typical length; redacted, it is never read.
    static let placeholderHint = DailyPriorityItem(
        kind: "milestone",
        itemKey: nil,
        title: "Placeholder title",
        body: "Placeholder text of one line",
        status: nil,
        actions: [],
        moduleKey: nil
    )
}

// MARK: - Localized copy (client-side keys only)

/// The hero's client-resolved copy. `title` / `body` on rail items arrive
/// already localized from the server; ONLY these `daily.today.*` and the action
/// `daily.action.*` label keys resolve here against the string catalog.
enum TodayHeroCopy {
    static var scoreLabel: String {
        local("daily.today.scoreLabel")
    }

    // `deltaFlat`, `readFullBriefing` and `scoreDelta(_:)` were
    // DELETED together with the "-X gegenüber Ausgangswert" chip and the
    // "Vollständiges Briefing lesen" button (operator b227: the ring tap already
    // opens the same Insights overview, and the delta chip was noise). Their
    // `daily.today.delta*` / `daily.today.readFullBriefing` catalog entries were
    // retired with them.

    /// The one word under the ring while last night's sleep is
    /// still missing (it replaced the `daily.today.sleepPending` sentence).
    static var provisional: String {
        local("daily.today.scoreProvisional")
    }

    static var worthALook: String {
        local("daily.today.worthALook")
    }

    // `provisionalA11y` was DELETED together with
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
    /// A key this build does not know (a newer server) falls back to the
    /// generic "View" instead of printing the raw key on the button.
    static func actionLabel(_ labelKey: String) -> String {
        let resolved = local(labelKey)
        return resolved == labelKey || labelKey.isEmpty ? local(fallbackActionKey) : resolved
    }

    static let fallbackActionKey = "daily.action.viewMilestone"

    // MARK: Resolution

    private static func local(_ key: String) -> String {
        String(localized: String.LocalizationValue(key))
    }

    private static func localFormat(_ key: String, _ argument: String) -> String {
        let template = String(localized: String.LocalizationValue(key))
        return String(format: template, argument)
    }
}
