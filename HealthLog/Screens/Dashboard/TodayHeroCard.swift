import SwiftUI

/// **Web-parity `TodayHero` — the promoted day's read at the top of the
/// dashboard.** A faithful SwiftUI port of `src/components/daily/today-hero.tsx`
/// (reworked in web v1.29.1: the multi-ring cluster was stripped, leaving a
/// single health ring). Backed by ``DailyDigestStore`` over `GET /api/daily/digest`.
///
/// iOS **renders the digest verbatim** — it recomputes no score / band / delta,
/// warms no AI on mount, and invents no colour: the ring is fully monochrome
/// (Wave 2 dropped the band-derived cap dot), and each priority card's status
/// wash is a restrained HL semantic tone. Composition, top → bottom:
///   1. the **heading** — the lead sentence (`briefingLead ?? line`) FULL WIDTH,
///      never squeezed by a trailing sibling (operator b227: "Überschrift gehört
///      über den Wert, nicht daneben");
///   2. one row pairing the muted top-signal text with the trailing health-score
///      ring lockup (a null score paints an honest provisional face); the ring is
///      a door into Insights;
///   3. an optional muted freshness note when `sleepPending`;
///   4. the bounded 0–3 "worth a look" rail of priority cards, or — when the day
///      is all-clear — a single calm "nothing needs your attention" line.
///
/// **Wave 2 (b227 operator walkthrough) removals:** the "read the full briefing"
/// button (the ring tap already opens the same Insights overview) and the
/// "-X gegenüber Ausgangswert" delta chip are gone, as is the hero parallax.
struct TodayHeroHost: View {
    /// Home-local front door for the `checkup.view` intent — the FALLBACK only:
    /// pushes the Vorsorge reminders manage surface via the dashboard's
    /// `showVorsorge` state when the due reminder has no capture flow.
    let onOpenVorsorge: () -> Void
    /// Wave 2 (2.5) — opens the bottom "Anstehende Einnahmen" slide-up sheet
    /// (`AnstehendeEinnahmenSheet`, the dashboard's `showIntakesSheet` state).
    /// The `dose.log` intent routes HERE instead of the medication detail screen:
    /// the sheet is the one-tap "Dosis erfassen" surface (operator b227).
    let onShowIntakes: () -> Void

    @Environment(DailyDigestStore.self) private var store
    @Environment(BackendAvailability.self) private var backend
    @Environment(AppRouter.self) private var router
    /// Wave 2 (2.6) — read ONLY inside `handleAction` (never in `body`), so this
    /// host registers no Observation dependency on the reminder list. Lets the
    /// hero's `checkup.view` inherit the retired standalone tile's superior
    /// routing: straight to the prefilled measure / check-in surface.
    @Environment(MeasurementRemindersStore.self) private var remindersStore

    var body: some View {
        content
            .task {
                // Server-authoritative, paired-only: warm only against a real
                // server, and only once (the store single-flights + SWR-free).
                guard backend.hasServer, store.digest == nil else { return }
                await store.load()
            }
    }

    @ViewBuilder
    private var content: some View {
        if backend.hasServer, !store.hasLoadedOnce {
            // Paired device, first load in flight (or about to start on `.task`)
            // — paint the no-layout-shift skeleton from the first frame so the
            // hero never flashes empty → skeleton → data.
            TodayHeroSkeleton()
        } else {
            loaded
        }
    }

    @ViewBuilder
    private var loaded: some View {
        switch store.presentation {
        case .loading:
            TodayHeroSkeleton()
        case let .data(digest):
            TodayHeroCard(
                digest: digest,
                coachActionInFlight: store.coachActionInFlight,
                onRingTap: { router.requestInsightsOverview() },
                onAction: handleAction,
                onDismiss: { itemKey in Task { await store.dismiss(itemKey: itemKey) } }
            )
        case .error:
            TodayHeroErrorCard { Task { await store.refresh() } }
        case .hidden:
            EmptyView()
        }
    }

    // MARK: - Action routing (intent → native surface)

    /// Maps a priority-card action's stable `intent` (and its web `href`) onto a
    /// native destination, mirroring the web deep-link map. The coach check-in's
    /// keep / let-go are the only MUTATING intents (they carry the plan id after
    /// the ":"); every other intent is pure navigation.
    private func handleAction(_ item: DailyPriorityItem, _ action: DailyPriorityItem.Action) {
        let intent = action.intent

        if let planId = planId(from: intent, prefix: "coach.checkin.keep:") {
            Task { await store.coachCheckinKeep(planId: planId) }
            return
        }
        if let planId = planId(from: intent, prefix: "coach.checkin.letGo:") {
            Task { await store.coachCheckinLetGo(planId: planId) }
            return
        }

        switch intent {
        case "coach.checkin.adjust":
            // Adjust opens the Coach. (Web seeds the composer via `?ask=`; the
            // iOS seed hand-off is a follow-up — the Coach still opens here.)
            router.apply(.coach, isAuthenticated: true)
        case "dose.log":
            // Wave 2 (2.5) — operator b227: "Medikament fällig" must open the
            // bottom upcoming-intakes sheet, NOT the medication detail screen.
            // The sheet is the canonical one-tap dose-logging surface (v0.5.6
            // HOME-COMPLIANCE-SHEET) and already lists today's pending intakes,
            // so the web `?highlight=<id>` hop is dropped entirely.
            onShowIntakes()
        case "sync.reconnect":
            router.requestSettingsIntegrations()
        case "checkup.view":
            openVorsorge()
        case "ecg.view":
            router.requestInsightsOverview()
        case "milestone.view", "pulse.view":
            if let slug = insightsSlug(from: action.href) {
                router.apply(.insights(metric: slug), isAuthenticated: true)
            } else {
                router.requestInsightsOverview()
            }
        default:
            // Unknown intent that still carries an in-app insights href → route
            // there; otherwise no-op (never a dead tap into a web path).
            if let slug = insightsSlug(from: action.href) {
                router.apply(.insights(metric: slug), isAuthenticated: true)
            }
        }
    }

    /// Wave 2 (2.6) — the `checkup.view` front door, inheriting the retired
    /// standalone `VorsorgeTile`'s routing doctrine (operator b198: "take me
    /// straight to DOING it"). Resolves the soonest due reminder and branches on
    /// the SHARED `VorsorgeCard.primaryAction` seam — prefilled measure sheet /
    /// mental-wellbeing check-in — falling back to the manage list only when the
    /// reminder is free-text / uncapturable (or nothing is due).
    private func openVorsorge() {
        guard let due = VorsorgeNextDue.nextDueNow(from: remindersStore.reminders) else {
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

    /// Recover the plan id appended after a mutating coach intent's prefix.
    private func planId(from intent: String, prefix: String) -> String? {
        guard intent.hasPrefix(prefix) else { return nil }
        let id = String(intent.dropFirst(prefix.count))
        return id.isEmpty ? nil : id
    }

    /// Extract an Insights metric slug from a web `/insights/<slug>` (or
    /// `/insights#<frag>`) href — `nil` → the Insights overview.
    private func insightsSlug(from href: String?) -> String? {
        guard let href, href.contains("/insights") else { return nil }
        if let range = href.range(of: "/insights/") {
            let slug = href[range.upperBound...].prefix { $0 != "?" && $0 != "#" && $0 != "/" }
            return slug.isEmpty ? nil : String(slug)
        }
        if let hashIndex = href.firstIndex(of: "#") {
            let frag = href[href.index(after: hashIndex)...]
            return frag.isEmpty ? nil : String(frag)
        }
        return nil
    }
}

// MARK: - The hero card

struct TodayHeroCard: View {
    let digest: DailyDigest
    var coachActionInFlight: Bool = false
    let onRingTap: () -> Void
    let onAction: (DailyPriorityItem, DailyPriorityItem.Action) -> Void
    let onDismiss: (String) -> Void

    var body: some View {
        HLCard(style: .elevated) {
            VStack(alignment: .leading, spacing: HLSpace.md) {
                readRow
                if digest.sleepPending {
                    freshnessNote
                }
                rail
            }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: Read row (heading ABOVE, then signal + ring on one row)

    /// **Wave 2 / 2.1 (operator b227).** The heading is its OWN full-width row —
    /// it no longer shares a band with the score, so a long German lead
    /// ("Heute ist vor allem ein Beobachtungstag…") wraps freely instead of being
    /// squeezed into a tall narrow column beside the ring. `fixedSize(vertical:)`
    /// guarantees it never truncates at any Dynamic-Type size. HIG typography:
    /// "at large sizes use a stacked layout where text appears above secondary
    /// items". Below it ONE row pairs the muted top-signal with the trailing ring
    /// lockup (echoing the web's trailing-edge ring).
    private var readRow: some View {
        VStack(alignment: .leading, spacing: HLSpace.md) {
            Text(verbatim: digest.lead)
                .font(.hlTitle3)
                .foregroundStyle(HLText.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(alignment: .center, spacing: HLSpace.lg) {
                if let signal = digest.topSignal, !signal.headline.isEmpty {
                    Text(verbatim: topSignalText(signal))
                        .font(.hlSubhead)
                        .foregroundStyle(HLText.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: HLSpace.sm)
                ringLockup
            }
        }
    }

    /// **Wave 2 / 2.3.** The score ring now renders with the EXACT Insights
    /// wellness-ring recipe (`InsightsTileStyle.prismUniform` → the arc-masked
    /// prism + steady glow, 96 pt, the `hlSubhead.weight(.medium)` label) so the
    /// hero and the Insights score cards can never drift apart visually.
    /// **Fully monochrome** — the band-derived cap dot is gone (operator b227:
    /// "keine Farbe"); the band still reaches VoiceOver via `ringAccessibilityLabel`,
    /// so no meaning was ever carried by colour alone (HIG color.md).
    private var ringLockup: some View {
        let appearance = InsightsTileStyle.prismUniform.appearance(signal: nil)
        return Button(action: onRingTap) {
            VStack(spacing: HLSpace.sm) {
                HLScoreRing(
                    fraction: ringFraction,
                    value: ringValue,
                    signal: appearance.ringSignal,
                    fillColor: appearance.ringFill,
                    trackColor: appearance.ringTrack,
                    centreValueColor: appearance.ringValueColor,
                    centreLabelColor: appearance.ringLabelColor,
                    accessibilityLabel: ringAccessibilityLabel
                )
                .frame(width: Self.ringDiameter, height: Self.ringDiameter)
                .insightsRingEffect(appearance.ringEffect, fraction: ringFraction, isHero: true)
                .modifier(WellnessRingShadow(active: appearance.ringShadowActive))

                Text(verbatim: TodayHeroCopy.scoreLabel)
                    .font(.hlSubhead.weight(.medium))
                    .foregroundStyle(appearance.labelColor)
                    .multilineTextAlignment(.center)
                // v1.35.0 (GH #83) — the hero shows the number and a one-word
                // label, so it is the surface that owes the answer to "made of
                // what?". Server-resolved provenance mark (R2, Herkunft): two
                // words under the label, no explanation and no instruction. The
                // sentence about what a chosen composition means for comparing
                // scores lives on the detail surface, where there is room.
                if digest.score?.runsOnChosenComposition == true {
                    Text(verbatim: HealthScorePresentation.chosenCompositionMark)
                        .font(.hlCaption)
                        .foregroundStyle(HLText.tertiary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(.plain)
        .hlPressable()
        .accessibilityHint(Text(verbatim: TodayHeroCopy.ringLink(metric: TodayHeroCopy.scoreLabel)))
        .accessibilityIdentifier("dashboard.todayHero.scoreRing")
    }

    /// The Insights diameter (`InsightsTileSurface` / `InsightsScoreCardsBlock`
    /// render at 96 pt). The hero ring stands ALONE, so it keeps the full 96 pt
    /// rather than the 84 pt 3-up shrink the score-rings row uses.
    private static let ringDiameter: CGFloat = 96

    // MARK: Freshness note

    private var freshnessNote: some View {
        HStack(spacing: HLSpace.xs) {
            Image(systemName: "moon")
                .font(.hlCaption)
                .foregroundStyle(HLText.tertiary)
                .accessibilityHidden(true)
            Text(verbatim: TodayHeroCopy.sleepPending)
                .font(.hlCaption)
                .foregroundStyle(HLText.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Worth-a-look rail

    @ViewBuilder
    private var rail: some View {
        let items = digest.rail
        if items.isEmpty {
            Text(verbatim: TodayHeroCopy.allClear)
                .font(.hlSubhead)
                .foregroundStyle(HLText.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                Text(verbatim: TodayHeroCopy.worthALook)
                    .font(.hlCaption.weight(.semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(HLText.tertiary)
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 240), spacing: HLSpace.md)],
                    alignment: .leading,
                    spacing: HLSpace.md
                ) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        PriorityRailCard(
                            item: item,
                            actionsPending: item.kindToken == .coachCheckin && coachActionInFlight,
                            onAction: { action in onAction(item, action) },
                            onDismiss: onDismiss
                        )
                    }
                }
            }
        }
    }

    // MARK: Derivations (render-only)

    private var ringFraction: Double {
        guard let score = digest.score else { return 0 }
        return max(0, min(1, score.value / 100))
    }

    /// The centre number, or an honest em-dash provisional face when null.
    private var ringValue: String {
        guard let score = digest.score else { return "–" }
        return String(Int(score.value.rounded()))
    }

    // Wave 2 / 2.3 — `ringSignal` (band → green/yellow/red cap dot) was DELETED.
    // The hero ring is fully monochrome now, matching the Insights rings; the
    // band survives for VoiceOver only, via `ringAccessibilityLabel`.

    private var ringAccessibilityLabel: String {
        guard let score = digest.score else {
            return "\(TodayHeroCopy.scoreLabel): \(TodayHeroCopy.provisionalA11y)"
        }
        let base = "\(TodayHeroCopy.scoreLabel) \(Int(score.value.rounded())) of 100"
        // v1.35.0 — the painted provenance mark is `accessibilityHidden`, so it
        // rides here instead: one element, one statement, read in context with
        // the number it qualifies rather than as a loose noun phrase after it.
        guard score.runsOnChosenComposition else { return base }
        return "\(base). \(HealthScorePresentation.chosenCompositionA11y)"
    }

    /// `headline` + optional pre-formatted delta ("· <delta>"), verbatim.
    private func topSignalText(_ signal: DailyDigest.TopSignal) -> String {
        guard let delta = signal.delta, !delta.isEmpty else { return signal.headline }
        return "\(signal.headline) · \(delta)"
    }
}

// MARK: - Priority rail card

/// The single card behind every "worth a look" rail item — composed from HL
/// primitives, a kind-derived SF Symbol, a restrained status-tone wash, an
/// optional dismiss (observational kinds only), and 1–3 one-tap actions.
struct PriorityRailCard: View {
    let item: DailyPriorityItem
    var actionsPending: Bool = false
    let onAction: (DailyPriorityItem.Action) -> Void
    let onDismiss: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            header
            if let body = item.body, !body.isEmpty {
                Text(verbatim: body)
                    .font(.hlSubhead)
                    .foregroundStyle(HLText.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !item.boundedActions.isEmpty {
                actionsRow
            }
        }
        .padding(HLSpace.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HLSurface.secondary, in: RoundedRectangle(cornerRadius: HLRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: HLRadius.card, style: .continuous)
                .strokeBorder(statusTint.opacity(0.30), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: HLSpace.sm) {
            if let symbol = kindSymbol {
                Image(systemName: symbol)
                    .font(.hlSubhead)
                    .foregroundStyle(statusTint)
                    .accessibilityHidden(true)
            }
            Text(verbatim: item.title)
                .font(.hlSubhead.weight(.semibold))
                .foregroundStyle(HLText.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if item.isDismissible, let itemKey = item.itemKey {
                Button {
                    onDismiss(itemKey)
                } label: {
                    Image(systemName: "xmark")
                        .font(.hlCaption.weight(.semibold))
                        .foregroundStyle(HLText.tertiary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .hlPressable()
                .accessibilityLabel(Text(verbatim: TodayHeroCopy.dismiss))
            }
        }
    }

    private var actionsRow: some View {
        HStack(spacing: HLSpace.sm) {
            ForEach(Array(item.boundedActions.enumerated()), id: \.offset) { _, action in
                Button {
                    onAction(action)
                } label: {
                    Text(verbatim: TodayHeroCopy.actionLabel(action.labelKey))
                        .font(.hlCaption.weight(.semibold))
                        .foregroundStyle(HLText.primary)
                        .padding(.vertical, HLSpace.xs)
                        .padding(.horizontal, HLSpace.sm)
                        .frame(minHeight: 36)
                        .background(
                            HLSurface.tertiary,
                            in: RoundedRectangle(cornerRadius: HLRadius.sm, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .hlPressable()
                .disabled(action.href == nil && actionsPending)
            }
            Spacer(minLength: 0)
        }
    }

    /// Deterministic SF Symbol per kind (the icon the serialisable item can't
    /// carry). Unknown kind → no icon.
    private var kindSymbol: String? {
        switch item.kindToken {
        case .doseWindow: "pills.fill"
        case .preventiveCare: "calendar.badge.clock"
        case .syncIssue: "arrow.triangle.2.circlepath"
        case .coachCheckin: "message"
        case .milestone: "medal"
        case .ecgNewRecording: "waveform.path.ecg"
        case .tensionWindow: "waveform.path"
        // CU-30 — same-time baseline: the day's cumulative standing against the
        // usual day at this hour. Steps-only on the rail, hence the walk glyph.
        case .sameTimeBaseline: "figure.walk"
        case .none: nil
        }
    }

    /// Status → a restrained HL semantic tone (border + icon). Info / unknown
    /// stay neutral (no colour) per monochrome doctrine.
    private var statusTint: Color {
        switch item.statusToken {
        case .success: HLColor.statusOK
        case .warning: HLColor.statusWarn
        case .destructive: HLColor.statusBad
        case .info, .none: HLColor.separator
        }
    }
}

// MARK: - Error card

private struct TodayHeroErrorCard: View {
    let onRetry: () -> Void

    var body: some View {
        HLCard(style: .elevated) {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                Text(verbatim: TodayHeroCopy.errorTitle)
                    .font(.hlSubhead.weight(.semibold))
                    .foregroundStyle(HLText.primary)
                Button(action: onRetry) {
                    Text(verbatim: TodayHeroCopy.retry)
                        .font(.hlCaption.weight(.semibold))
                        .foregroundStyle(HLText.primary)
                        .padding(.vertical, HLSpace.xs)
                        .padding(.horizontal, HLSpace.sm)
                        .frame(minHeight: 36)
                        .background(
                            HLSurface.tertiary,
                            in: RoundedRectangle(cornerRadius: HLRadius.sm, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .hlPressable()
            }
        }
    }
}
