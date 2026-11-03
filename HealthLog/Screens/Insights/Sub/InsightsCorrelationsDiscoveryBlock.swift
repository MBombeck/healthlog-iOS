import SwiftUI

/// v0.12 — the discovered-correlations overview block. Renders the
/// FDR-controlled behaviour × outcome associations from
/// `GET /api/insights/correlations` (`CorrelationsDiscoveryStore.presentable`),
/// one mono card per surviving pair plus an honest footer.
///
/// **DESCRIPTIVE, NEVER CAUSAL.** This is the iOS twin of the web's
/// correlation-discovery surface: every pair states a statistical *association*
/// ("X hängt mit Y zusammen"), NEVER a cause/effect claim ("X verbessert Y").
/// The per-pair line mirrors the server's conservative framing; `n` and `r`
/// (and the significance footer) are shown so the user can judge it themselves.
///
/// **HONEST-ONLY + self-suppressing.** Renders ONLY the pairs the server
/// returned. When the surface is gated off OR nothing survived the FDR control,
/// `metrics` is empty and the block self-suppresses (`EmptyView`) — not an
/// error, not an empty box.
///
/// **Server-derived.** Pure server compute, no on-device fallback — the call
/// site gates the block on `BackendAvailability.hasServer`. Monochrome, one
/// card system (`HLCard`), `HLSpace` grid, `Font.hl*` tokens, reduce-motion
/// gated. Mounts BELOW the derived-insights block in the overview.
struct InsightsCorrelationsDiscoveryBlock: View {
    /// The discovered pairs to render, ordered strongest-first (sourced from
    /// `CorrelationsDiscoveryStore.presentable`). Empty → the block hides.
    let pairs: [DiscoveredCorrelation]
    /// Behaviour × outcome pairs the server assessed (the honest footer). Only
    /// rendered when at least one pair surfaced.
    let pairsTested: Int
    /// **A360 H2 (v0156)** — "Ask the coach about this" affordance per pair. The
    /// host opens the Coach pre-scoped to BOTH channels in the pair (a localized
    /// opener + `scope { sources: [behaviour, outcome] }`) so the coach reads a
    /// snapshot covering the exact relationship the card describes. `nil` (e.g.
    /// when the coach surface is gated off) hides the affordance.
    var onAskCoach: ((DiscoveredCorrelation) -> Void)?
    /// **CU-33** — the pairs the person has marked as not relevant for them
    /// (`CorrelationsDiscoveryStore.dismissedPairs`). Kept out of the main list
    /// but reachable behind a disclosure, because the statement is reversible.
    var dismissedPairs: [DiscoveredCorrelation] = []
    /// **CU-33** — records the person's relevance statement: `true` = "not
    /// relevant for me", `false` = takes that back. `nil` hides both controls
    /// (e.g. no host store wired).
    var onSetDismissed: ((DiscoveredCorrelation, Bool) -> Void)?
    /// Pairs whose statement is in flight — the control is disabled meanwhile.
    var pendingIDs: Set<String> = []
    /// Set when a statement could not be saved — the optimistic change has
    /// already been rolled back, and this says so.
    var actionError: String?
    /// **C1** — deep-links a pair's channel into its own Insights page. `nil`
    /// only hides the per-channel jumps INSIDE the detail sheet; the sheet
    /// itself is offered either way, because "one shape for every entry" is the
    /// whole point of C1.
    var onSelectMetric: ((MetricKind) -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appContainer) private var appContainer
    /// **C1** — the id of the pair whose follow-up section is open. One shape for
    /// every entry: the row that looks pursuable is pursuable, and there is
    /// nothing else to learn which rows are which.
    @State private var expandedPairID: String?
    /// Disclosure state for the not-relevant group. View-local: it is a way of
    /// looking at the list, not part of the person's data.
    @State private var showsDismissed = false
    /// Presentation-only disclosure for the complete block.
    @State private var isExpanded = Self.isInitiallyExpanded

    var body: some View {
        if !pairs.isEmpty || !dismissedPairs.isEmpty {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                DisclosureGroup(isExpanded: $isExpanded) {
                    VStack(alignment: .leading, spacing: HLSpace.sm) {
                        // 1.4 B2 — the reading instruction once, at the top,
                        // instead of a footer plus a second "Quellen" under the
                        // last card (each card carries its own citation).
                        if !pairs.isEmpty {
                            Text(Self.footer(pairsTested: pairsTested))
                                .font(.hlCaption)
                                .foregroundStyle(HLText.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("insights.correlations.discovery.footer")
                        }
                        VStack(spacing: HLSpace.sm) {
                            ForEach(pairs) { pair in
                                card(for: pair)
                            }
                        }
                        if let actionError {
                            Text(actionError)
                                .font(.hlCaption)
                                .foregroundStyle(HLText.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("insights.correlations.discovery.actionError")
                        }
                        dismissedSection
                    }
                    .padding(.top, HLSpace.sm)
                } label: {
                    Text(String(localized: "Relationships in your data"))
                        .font(.hlHeadline)
                        .foregroundStyle(HLText.primary)
                }
                .tint(HLText.secondary)
                .accessibilityValue(Self.disclosureAccessibilityValue(isExpanded: isExpanded))
                .accessibilityIdentifier("insights.correlations.discovery.disclosure")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .transition(reduceMotion ? .identity : .opacity)
            .transaction { transaction in
                if reduceMotion {
                    transaction.animation = nil
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("insights.correlations.discovery")
        }
    }

    // MARK: - Not-relevant group (reversible by design)

    @ViewBuilder
    private var dismissedSection: some View {
        if !dismissedPairs.isEmpty {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                Button {
                    showsDismissed.toggle()
                } label: {
                    HStack(spacing: HLSpace.xs) {
                        Image(systemName: showsDismissed ? "chevron.down" : "chevron.right")
                            .font(.hlIcon(HLIconSize.sm))
                        Text(Self.dismissedToggleLabel(count: dismissedPairs.count))
                            .font(.hlFootnote)
                    }
                    .foregroundStyle(HLText.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("insights.correlations.discovery.dismissedToggle")
                if showsDismissed {
                    VStack(spacing: HLSpace.sm) {
                        ForEach(dismissedPairs) { pair in
                            card(for: pair)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Discovered-pair card

    /// 1.4 B2 — headline, the server's reading, then ONE foot line: "Details"
    /// and the card's citation. Everything else a card used to stack below
    /// (the n/r line, the set-aside and came-back notes, the coach link, the
    /// relevance control) opens with "Details", so a card is three lines.
    private func card(for pair: DiscoveredCorrelation) -> some View {
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.xs) {
                // The descriptive headline — "<behaviour> hängt mit <outcome>
                // zusammen", direction-aware, NEVER causal.
                Text(Self.headline(for: pair))
                    .font(.hlHeadline)
                    .foregroundStyle(HLText.primary)
                // The server's own conservative interpretation prose.
                if !pair.interpretation.isEmpty {
                    Text(pair.interpretation)
                        .font(.hlBody)
                        .foregroundStyle(HLText.secondary)
                }
                // C1 — the follow-up, on EVERY card, and 1.4.1 — the citation
                // Apple photographed, on every card and visible without
                // expanding anything: one line, stacked when it does not fit.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: HLSpace.lg) {
                        followUpLink(for: pair)
                        Spacer(minLength: 0)
                        HLSourcesLink(topic: .correlations)
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        followUpLink(for: pair)
                        HLSourcesLink(topic: .correlations)
                    }
                }
                if expandedPairID == pair.id {
                    InsightsCorrelationFollowUpSection(
                        pair: pair,
                        onSelectMetric: onSelectMetric,
                        onAskCoach: appContainer.offersCoach ? onAskCoach : nil
                    ) {
                        if let onSetDismissed, pair.isDismissable {
                            relevanceButton(for: pair, action: onSetDismissed)
                        }
                    }
                }
            }
        }
        // A dismissed pair stays legible but recedes — it is set aside, not
        // deleted, and the person can put it back.
        .opacity(pair.isDismissed ? 0.6 : 1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Self.accessibilityLabel(for: pair))
    }

    /// The relevance statement control. Deliberately phrased as the person's
    /// own judgement ("Not relevant for me"), NOT as a verdict on the data and
    /// NOT as a delete — and it reads back the other way once made.
    private func relevanceButton(
        for pair: DiscoveredCorrelation,
        action: @escaping (DiscoveredCorrelation, Bool) -> Void
    ) -> some View {
        Button {
            action(pair, !pair.isDismissed)
        } label: {
            HStack(spacing: HLSpace.xs) {
                Image(systemName: pair.isDismissed ? "arrow.uturn.backward" : "eye.slash")
                    .font(.hlIcon(HLIconSize.sm))
                Text(pair.isDismissed ? Self.restoreLabel : Self.dismissLabel)
                    .font(.hlFootnote)
            }
            .foregroundStyle(HLText.secondary)
        }
        .buttonStyle(.plain)
        .disabled(pendingIDs.contains(pair.id))
        .frame(minHeight: 44)
        .accessibilityIdentifier("insights.correlations.discovery.relevance")
    }

    /// **C1** — the one follow-up affordance, identical on every card.
    ///
    /// The glyph and the behaviour are one thing here: the row carries a
    /// disclosure *because* it opens something, it opens the same something
    /// whether or not the pair's channels have Insights pages of their own, and
    /// the glyph states which of the two positions it is in. The difference
    /// between a pair that can be pursued further and one that cannot is stated
    /// INSIDE the section, in words, rather than by the silent presence or
    /// absence of an affordance out here — which is what made the unmapped
    /// entries read as dead rows.
    private func followUpLink(for pair: DiscoveredCorrelation) -> some View {
        let isOpen = expandedPairID == pair.id
        return Button {
            expandedPairID = isOpen ? nil : pair.id
        } label: {
            HStack(spacing: HLSpace.xs) {
                Text(Self.followUpLabel)
                    .font(.hlFootnote)
                Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                    .font(.hlIcon(HLIconSize.sm))
            }
            .foregroundStyle(HLText.secondary)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("insights.correlations.discovery.followUp")
    }

    // MARK: - Pure resolvers (nonisolated for unit tests)

    /// Correlations remain loaded and available, but start visually quiet.
    nonisolated static let isInitiallyExpanded = false

    /// Direction-aware descriptive headline. Both arms are ASSOCIATIONS — the
    /// positive arm reads "geht einher mit mehr/höher", the negative
    /// "geht einher mit weniger/niedriger". Never "verbessert"/"verschlechtert".
    nonisolated static func headline(for pair: DiscoveredCorrelation) -> String {
        let behaviour = behaviourLabel(for: pair)
        let outcome = outcomeLabel(for: pair)
        switch pair.direction {
        case .positive:
            return String(
                localized: "More \(behaviour) tends to go with more \(outcome) the next day",
                comment: "Descriptive (non-causal) positive correlation headline"
            )
        case .negative:
            return String(
                localized: "More \(behaviour) tends to go with less \(outcome) the next day",
                comment: "Descriptive (non-causal) negative correlation headline"
            )
        }
    }

    /// `n = … · r = …` — paired-day count + Pearson r (2 dp). The transparency
    /// line, mirrored from the server values, never fabricated.
    nonisolated static func statLine(for pair: DiscoveredCorrelation, locale: Locale = .current) -> String {
        let r = HLNumberFormat.decimal(pair.r, fractionDigits: 2, locale: locale)
        let strength = strengthLabel(pair.strength)
        return String(
            localized: "Based on \(pair.n) days · r = \(r) (\(strength))",
            comment: "Correlation stat line: paired-day count + Pearson r + strength word"
        )
    }

    /// Honest footer — how many pairs were assessed to surface these. Mirrors
    /// the web's "N pairs tested" disclosure so the surfaced set is contextual.
    nonisolated static func footer(pairsTested: Int) -> String {
        String(
            localized: "From \(pairsTested) relationships checked. These are associations, not causes.",
            comment: "Correlation-discovery honest footer (pairs tested + non-causal caveat)"
        )
    }

    /// Conservative strength word from the |r| bucket.
    nonisolated static func strengthLabel(_ strength: DiscoveredCorrelation.Strength) -> String {
        switch strength {
        case .weak: String(localized: "weak", comment: "Correlation strength: weak")
        case .moderate: String(localized: "moderate", comment: "Correlation strength: moderate")
        case .strong: String(localized: "strong", comment: "Correlation strength: strong")
        }
    }

    /// VoiceOver summary — descriptive, includes n + r in words.
    nonisolated static func accessibilityLabel(for pair: DiscoveredCorrelation) -> String {
        "\(headline(for: pair)). \(statLine(for: pair))."
    }

    // MARK: - C1 — follow-up copy

    /// The follow-up affordance's label. Deliberately the same on every card:
    /// it names the presentation, not the destination, because the destination
    /// differs and the affordance must not.
    nonisolated static var followUpLabel: String {
        String(
            localized: "insights.correlations.followUp",
            comment: "Correlation card — opens the pair's detail shape (C1: every entry can be pursued)"
        )
    }

    // MARK: - CU-33 — relevance copy

    /// The person's statement, phrased as their own judgement. Not "wrong",
    /// not "hide forever", not a delete.
    nonisolated static var dismissLabel: String {
        String(
            localized: "Not relevant for me",
            comment: "Correlation card — mark this relationship as not relevant to me"
        )
    }

    /// Taking the statement back.
    nonisolated static var restoreLabel: String {
        String(
            localized: "Relevant after all",
            comment: "Correlation card — undo the not-relevant statement"
        )
    }

    /// Disclosure label for the set-aside group.
    nonisolated static func dismissedToggleLabel(count: Int) -> String {
        String(
            localized: "Set aside as not relevant (\(count))",
            comment: "Correlation block — disclosure for the pairs the person marked not relevant"
        )
    }
}
