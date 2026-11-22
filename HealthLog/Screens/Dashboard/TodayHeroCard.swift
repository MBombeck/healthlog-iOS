import SwiftUI

/// **Web-parity `TodayHero` — the promoted day's read at the top of the
/// dashboard.** A faithful SwiftUI port of `src/components/daily/today-hero.tsx`
/// (reworked in web v1.29.1: the multi-ring cluster was stripped, leaving a
/// single health ring). Backed by ``DailyDigestStore`` over `GET /api/daily/digest`.
///
/// iOS **renders the digest verbatim** — it recomputes no score / band / delta,
/// warms no AI on mount, and invents no colour: the ring is fully monochrome
/// (Wave 2 dropped the band-derived cap dot), and each
/// hint's status shows only on its symbol. Composition, top → bottom:
///   1. the **heading** — the lead sentence (`lead.text`, else
///      `briefingLead ?? line`) FULL WIDTH,
///      never squeezed by a trailing sibling (operator b227: "Überschrift gehört
///      über den Wert, nicht daneben");
///   2. one row: on the left three or four equal fact pairs; on the right
///      the health-score ring lockup with its footnotes (steady weeks, Rest
///      Mode), rendered ONLY when the digest carries a score (25-02 /
///      E-2026-08-29 #2). The lead already says what the muted signal line
///      said, so the hero no longer shows it. The layout is
///      ``TodayHeroReadLayout``; the ring is a door into Insights;
///   3. UNDER the card, as a section of its own, the bounded 0–3 "worth a
///      look" hints (``TodayHeroWorthALookSection``), one slim card each.
///
/// **Wave 2 (b227 operator walkthrough) removals:** the "read the full briefing"
/// button (the ring tap already opens the same Insights overview) and the
/// "-X gegenüber Ausgangswert" delta chip are gone, as is the hero parallax.
struct TodayHeroHost: View {
    /// Home-local front door for the `checkup.view` intent — the FALLBACK only:
    /// pushes the Vorsorge reminders manage surface via the dashboard's
    /// `showVorsorge` state when the due reminder has no capture flow.
    let onOpenVorsorge: () -> Void
    /// Opens the bottom "Anstehende Einnahmen" slide-up sheet
    /// (`AnstehendeEinnahmenSheet`, the dashboard's `showIntakesSheet` state).
    /// The `dose.log` intent routes HERE instead of the medication detail screen:
    /// the sheet is the one-tap "Dosis erfassen" surface (operator b227).
    let onShowIntakes: () -> Void
    /// The window is short (``TodayLayout/isShortWindow(height:width:)``): the hero
    /// keeps to its short-window height.
    var isShortWindow = false

    @Environment(DailyDigestStore.self) private var store
    @Environment(AppRouter.self) private var router
    /// Read ONLY inside `handleAction` (never in `body`), so this
    /// host registers no Observation dependency on the reminder list. Lets the
    /// hero's `checkup.view` inherit the retired standalone tile's superior
    /// routing: straight to the prefilled measure / check-in surface.
    @Environment(MeasurementRemindersStore.self) private var remindersStore
    /// 1.7: the medication fact and the dose hints follow the confirmed
    /// today rows. Optional, so a host without the store keeps the server's.
    @Environment(MedicationsStore.self) private var medicationsStore: MedicationsStore?

    var body: some View {
        content
            .task {
                // Server-authoritative: warm only once (the store
                // single-flights + SWR-free).
                guard store.digest == nil else { return }
                await store.load()
            }
    }

    @ViewBuilder
    private var content: some View {
        if !store.hasLoadedOnce {
            // First load in flight (or about to start on `.task`)
            // — paint the no-layout-shift skeleton from the first frame so the
            // hero never flashes empty → skeleton → data.
            TodayHeroSkeleton(isShortWindow: isShortWindow)
        } else {
            loaded
        }
    }

    @ViewBuilder
    private var loaded: some View {
        switch store.presentation {
        case .loading:
            TodayHeroSkeleton(isShortWindow: isShortWindow)
        case let .data(digest):
            // The hints stand under the hero as a section of their own, one
            // card gap apart, so the hero carries only the day's read.
            VStack(alignment: .leading, spacing: HLLayout.cardGap) {
                let medicationState = medicationsStore?.todayState ?? .unknown
                TodayHeroCard(
                    digest: digest,
                    onRingTap: { router.requestInsightsOverview() },
                    isShortWindow: isShortWindow,
                    medicationState: medicationState
                )
                TodayHeroWorthALookSection(
                    items: MedicationDigestFilter.visible(digest.rail, state: medicationState),
                    coachActionInFlight: store.coachActionInFlight,
                    onAction: handleAction,
                    onDismiss: { itemKey in Task { await store.dismiss(itemKey: itemKey) } }
                )
            }
            .hlContainerGap(HLLayout.cardGap)
        case .error:
            errorCard
        case .hidden:
            EmptyView()
        }
    }

    /// The hero's own read failed while the rest of Home stands: one line
    /// and the way to try again, in the hero's place.
    private var errorCard: some View {
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                Text(verbatim: TodayHeroCopy.errorTitle)
                    .hlText(.rowTitle)
                HLButton(Text(verbatim: TodayHeroCopy.retry), variant: .secondary) {
                    Task { await store.refresh() }
                }
            }
        }
    }

    // MARK: - Action routing (intent → native surface)

    /// Maps a priority-card action onto its native destination
    /// (``TodayHeroActionRoute``, mirroring the web deep-link map) and goes.
    private func handleAction(_ item: DailyPriorityItem, _ action: DailyPriorityItem.Action) {
        switch TodayHeroActionRoute.resolve(intent: action.intent, href: action.href) {
        case let .coachKeep(planId):
            Task { await store.coachCheckinKeep(planId: planId) }
        case let .coachLetGo(planId):
            Task { await store.coachCheckinLetGo(planId: planId) }
        case .coach:
            router.apply(.coach, isAuthenticated: true)
        case .intakes:
            // Operator b227: "Medikament fällig" opens the
            // bottom upcoming-intakes sheet, the canonical one-tap dose-logging
            // surface, not the medication detail screen.
            onShowIntakes()
        case .integrations:
            router.requestSettingsIntegrations()
        case .checkupFrontDoor:
            openVorsorge(for: item)
        case .checkupsList:
            // `visit.view` for several visits: Vorsorge, whose
            // "Nächster Termin" shows the soonest.
            router.focusVisit(nil)
            onOpenVorsorge()
        case let .visit(id):
            // VISIT — one named visit: Vorsorge with that visit.
            router.focusVisit(id)
            onOpenVorsorge()
        case .insightsOverview:
            router.requestInsightsOverview()
        case let .insights(slug):
            router.apply(.insights(metric: slug), isAuthenticated: true)
        case .none:
            break
        }
    }

    /// The `checkup.view` front door, inheriting the retired
    /// standalone `VorsorgeTile`'s routing doctrine (operator b198: "take me
    /// straight to DOING it"). Resolves the soonest due reminder and branches on
    /// the SHARED `VorsorgeCard.primaryAction` seam — prefilled measure sheet /
    /// mental-wellbeing check-in — falling back to the manage list only when the
    /// reminder is free-text / uncapturable (or nothing is due). v1.39.2 — an
    /// `upcoming_visit` item carries the same intent and always opens the list
    /// (``VorsorgeNextDue/frontDoorReminder(forRailKind:reminders:now:calendar:)``).
    private func openVorsorge(for item: DailyPriorityItem) {
        guard let due = VorsorgeNextDue.frontDoorReminder(
            forRailKind: item.kind,
            reminders: remindersStore.reminders
        ) else {
            onOpenVorsorge()
            return
        }
        switch VorsorgeCard.primaryAction(for: due) {
        case let .measure(kind):
            router.requestMeasure(prefill: kind)
        case .checkIn:
            router.requestMentalWellbeingCheckIn()
        case .markDone:
            onOpenVorsorge()
        }
    }
}

// MARK: - The hero card

struct TodayHeroCard: View {
    let digest: DailyDigest
    let onRingTap: () -> Void
    /// The loading skeleton draws this card with a shimmer circle in the
    /// ring's place, so both have one height.
    var isPlaceholder = false
    /// In a short window the card stays at or under
    /// ``TodayLayout/shortWindowHeroHeight``: the lead keeps two lines and
    /// the facts stay beside the ring until an accessibility size.
    var isShortWindow = false
    /// 1.7: what the medication fact may say (``MedicationDigestFilter``).
    var medicationState: MedicationTodayState = .unknown

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// The lead stays a heading but never pushes the facts down the page.
    static let leadLineLimit = TodayLayout.standardLeadLines

    var body: some View {
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.md) {
                leadText
                readRow
            }
            // Across a wide iPad the card spans the column, its read does
            // not: the lead keeps a reading length and the ring stays beside
            // the facts as one group (``TodayLayout/heroReadWidth(contentWidth:)``).
            .frame(maxWidth: TodayLayout.heroReadMaximumWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: Lead (full width, ABOVE everything)

    /// The day's sentence is its OWN full-width row (operator b227:
    /// "Überschrift gehört über den Wert, nicht daneben"), running text at
    /// most three lines. It reads as prose, so the area header under the card
    /// stays the only semibold line of its size. At accessibility sizes it
    /// wraps freely, so nothing is cut where the text is needed most.
    private var leadText: some View {
        Text(verbatim: digest.lead)
            .hlText(.prose)
            .lineLimit(TodayLayout.leadLineLimit(
                isShortWindow: isShortWindow,
                isAccessibilitySize: dynamicTypeSize.isAccessibilitySize
            ))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Read row (column beside the ring)

    private var stacked: Bool {
        TodayLayout.stacksRead(dynamicTypeSize, isShortWindow: isShortWindow)
    }

    private var readLayout: TodayHeroReadLayout {
        .resolve(
            hasScore: Self.availableScore(digest) != nil,
            hasLeftContent: TodayHeroFacts.hasContent(digest),
            stacked: stacked
        )
    }

    /// One row under the lead: the facts on the left, the ring on the right,
    /// both on one vertical centre. Without a score the facts take the width
    /// and Rest Mode stands under them; without facts the ring stands
    /// centred rather than beside an empty half.
    @ViewBuilder
    private var readRow: some View {
        let layout = readLayout
        let column = TodayHeroFacts(
            digest: digest,
            columns: layout.factColumns(factCount: TodayHeroFacts.facts(digest).count, stacked: stacked),
            wrapsValues: dynamicTypeSize.isAccessibilitySize,
            medicationState: medicationState
        )
        switch layout {
        case .columnBesideRing:
            HStack(alignment: .center, spacing: HLLayout.cardGap) {
                column
                    .frame(maxWidth: .infinity, alignment: .leading)
                ring
                    .frame(width: Self.ringColumnWidth)
            }
        case .columnAboveRing:
            VStack(alignment: .leading, spacing: HLLayout.cardGap) {
                column
                ring
                    .frame(maxWidth: .infinity)
            }
        case .ringCentred:
            ring
                .frame(maxWidth: .infinity)
        case .columnFullWidth:
            VStack(alignment: .leading, spacing: HLSpace.md) {
                column
                ForEach(TodayHeroFacts.footnotes(digest), id: \.self) { line in
                    TodayHeroFootnote(text: line, alignment: .leading)
                }
            }
        case .none:
            EmptyView()
        }
    }

    @ViewBuilder
    private var ring: some View {
        if let score = Self.availableScore(digest) {
            ringLockup(score: score)
        }
    }

    /// Beside the facts the ring's column keeps one width, wide enough for
    /// its word, so a footnote wraps under the ring instead of pushing the
    /// facts into a narrower column.
    static let ringColumnWidth: CGFloat = 128

    /// **The availability gate.** The score itself
    /// is SERVER-computed — `Math.round(mean(eligible pillars))` over the
    /// composition the health-score-config route resolves — and iOS never
    /// recomputes or reweights. What the client owns is availability: a
    /// digest without a score means zero available inputs, and the ring
    /// disappears from the dashboard entirely — no empty state, no
    /// explainer, no provisional face. Any present score renders unchanged,
    /// however narrow its backing subset: a one-input score is that input's
    /// score, by decision.
    static func availableScore(_ digest: DailyDigest) -> DailyDigest.Score? {
        digest.score
    }

    /// The score ring now renders with the EXACT Insights
    /// wellness-ring recipe (`InsightsTileStyle.prismUniform` → the arc-masked
    /// prism + steady glow, 96 pt, the `hlSubhead.weight(.medium)` label) so the
    /// hero and the Insights score cards can never drift apart visually.
    /// **Fully monochrome** — the band-derived cap dot is gone (operator b227:
    /// "keine Farbe"); the band still reaches VoiceOver via `ringAccessibilityLabel`,
    /// so no meaning was ever carried by colour alone (HIG color.md).
    ///
    /// **The painted „Eigene Auswahl" mark is
    /// GONE.** It overloaded the tile visually (operator decision). The mark
    /// was `accessibilityHidden` here from the day it shipped, so nothing
    /// spoken was removed: the provenance statement still rides the ring's
    /// accessibility label (see `ringAccessibilityLabel`), and the full
    /// explanation keeps living on the detail surfaces.
    private func ringLockup(score: DailyDigest.Score) -> some View {
        let appearance = InsightsTileStyle.prismUniform.appearance(signal: nil)
        let fraction = max(0, min(1, score.value / 100))
        return Button(action: onRingTap) {
            VStack(spacing: HLSpace.sm) {
                // The ring stands alone, centred on the facts beside it: no
                // word and no footnote under it (operator decision 14.11.).
                // The name, the score and the steady weeks still reach
                // VoiceOver through `ringAccessibilityLabel`.
                ringGraphic(score: score, appearance: appearance, fraction: fraction)
                // Last night's sleep is still missing: one word with
                // the score it qualifies, no sentence of its own.
                if digest.sleepPending {
                    Text(verbatim: TodayHeroCopy.provisional)
                        .hlText(.footnote)
                }
            }
        }
        .hlPressable()
        .allowsHitTesting(!isPlaceholder)
        .accessibilityHint(Text(verbatim: TodayHeroCopy.ringLink(metric: TodayHeroCopy.scoreLabel)))
        .accessibilityIdentifier("dashboard.todayHero.scoreRing")
    }

    @ViewBuilder
    private func ringGraphic(
        score: DailyDigest.Score,
        appearance: InsightsTileAppearance,
        fraction: Double
    ) -> some View {
        if isPlaceholder {
            HLSkeleton(.circle, width: Self.ringDiameter, height: Self.ringDiameter)
        } else {
            HLScoreRing(
                fraction: fraction,
                value: String(Int(score.value.rounded())),
                signal: appearance.ringSignal,
                fillColor: appearance.ringFill,
                trackColor: appearance.ringTrack,
                centreValueColor: appearance.ringValueColor,
                centreLabelColor: appearance.ringLabelColor,
                accessibilityLabel: ringAccessibilityLabel(score: score)
            )
            .frame(width: Self.ringDiameter, height: Self.ringDiameter)
            .insightsRingEffect(appearance.ringEffect, fraction: fraction, isHero: true)
            .modifier(WellnessRingShadow(active: appearance.ringShadowActive))
        }
    }

    /// The Insights diameter (`InsightsTileSurface` / `InsightsScoreCardsBlock`
    /// render at 96 pt). The hero ring stands ALONE, so it keeps the full 96 pt
    /// rather than the 84 pt 3-up shrink the score-rings row uses.
    private static let ringDiameter: CGFloat = 96

    // MARK: Derivations (render-only)

    // `ringSignal` (band → green/yellow/red cap dot) was DELETED.
    // The hero ring is fully monochrome now, matching the Insights rings; the
    // band survives for VoiceOver only, via `ringAccessibilityLabel`.
    //
    // The nil-score branches (`ringFraction` 0,
    // `ringValue` en-dash, the "provisional" VoiceOver face) were DELETED with
    // the provisional face itself: the ring renders only through
    // `availableScore`, so every derivation now takes the score it renders.

    /// v1.35.0 — the provenance statement is spoken, not painted: one element,
    /// one statement, read in context with the number it qualifies. 25-02 made
    /// this the ONLY carrier (the painted mark is gone), so this label is now
    /// the accessibility function the caption used to duplicate.
    private func ringAccessibilityLabel(score: DailyDigest.Score) -> String {
        var label = "\(TodayHeroCopy.scoreLabel) \(Int(score.value.rounded())) of 100"
        if digest.sleepPending { label += ", \(TodayHeroCopy.provisional)" }
        // The footnotes (steady weeks, Rest Mode) are no longer painted
        // under the ring; VoiceOver still hears them with the score.
        for line in TodayHeroFacts.footnotes(digest) {
            label += ". \(line)"
        }
        guard score.runsOnChosenComposition else { return label }
        return "\(label). \(HealthScorePresentation.chosenCompositionA11y)"
    }
}
