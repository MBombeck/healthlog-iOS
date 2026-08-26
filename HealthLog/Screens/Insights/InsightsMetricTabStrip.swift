import SwiftUI

/// v0.11 W22-W1 — the web-mirror Insights tab strip.
///
/// Mirrors the web `<InsightsTabStrip>` (`src/components/insights/insights-tab-
/// strip.tsx`): a horizontally-scrollable row of pills, the first always
/// **Übersicht** (the web `Overview` pill → `INSIGHTS_OVERVIEW_PATH`), the rest
/// per-metric. The strip is the navigation spine of the Insights tab — selecting
/// `Übersicht` shows the existing Insights overview body, selecting a metric pill
/// opens that metric's detail.
///
/// **Order + visibility** come from `InsightsLayoutStore` (the server-synced
/// `/api/insights/layout` order/visibility the operator already curates), so the
/// strip order tracks the tile order the operator set — one source of truth, no
/// second layout vocabulary. **Availability** is gated on `MeasurementsStore`
/// (mirror web `:290-306` "≥1 observation in the window"): a metric pill renders
/// ONLY when the operator has data for that kind AND the layout has it visible.
/// No availability → only the Übersicht pill, exactly like web. As data lands a
/// pill "lights up" — there are never dead pills.
///
/// **Look:** monochrome (Doctrine — colour is signal only). The selected pill is
/// a filled `HLText.primary` capsule with inverted label; unselected pills are
/// quiet outlined capsules. ONE glass surface budget is respected: the strip
/// itself carries no glass (the nav scroll-edge owns the Insights header glass);
/// pills are flat fills, never glass on content.
struct InsightsMetricTabStrip: View {
    /// The current selection (`.overview` or `.metric(kind)`), owned by the host
    /// container so the content area can switch off the same value.
    @Binding var selection: InsightsTabSelection

    /// V0150 — the FROZEN ordered selection list shared verbatim with the
    /// container's swipe pager (`InsightsContainerScreen.pagerOrder`). The strip
    /// renders pills from EXACTLY this list (only folding grouped metrics into
    /// category pills), so the highlighted pill and the visible page can never
    /// drift — and, critically, the strip's pill order is anchor-stable for the
    /// same reason the pager is: it does not re-derive a possibly-grown order from
    /// raw availability. Replaces the prior `layout` + availability inputs.
    let orderedSelections: [InsightsTabSelection]

    /// Q-insights-scroll — fired on EVERY pill tap (including a re-tap of the
    /// ALREADY-selected pill). A plain `selection = sel` write is a no-op when the
    /// value is unchanged, so it can never carry the "re-tap the active page"
    /// intent; the container needs an explicit per-tap signal to drive the
    /// animated scroll-to-top of the active page. Defaults to a no-op so existing
    /// previews compile unchanged. The swipe path never calls this (it moves
    /// `selection` via the pager), so only a deliberate pill tap animates a reset.
    var onPillTap: (InsightsTabSelection) -> Void = { _ in }

    /// v0.14.1 — tapped the trailing "customise" affordance at the strip's end.
    /// Opens the strip-customise sheet (reorder + show/hide metric tabs). The
    /// affordance only renders when this is wired (defaults to a no-op so the
    /// existing previews + any non-customisable embed compile unchanged AND the
    /// trailing pencil is absent there). Subtle + monochrome, mirroring the
    /// quiet outlined pill treatment.
    var onCustomize: (() -> Void)?

    /// **22-01 (R4) / 22-02 — the honest note about a strip that knows nothing,
    /// carried INSIDE the strip's own row.**
    ///
    /// `nil` in every ordinary state, and in every embed that does not pass one,
    /// so this file's composition is unchanged when there is nothing to say.
    ///
    /// It lives here rather than under the strip because 22-02's accessibility
    /// gate measured what a line of prose costs in PINNED chrome: at
    /// AccessibilityXXXL an unbounded caption below the divider took 217pt of an
    /// 874pt screen and the Insights score grid stopped materialising behind it;
    /// bounded to two lines it still took 113pt and cost a score card. The strip
    /// already reserves a row whose height the pills set, and the note is
    /// single-line and no taller than a pill — so it displaces nothing, and the
    /// horizontal room it uses is room the short strip was not using anyway.
    var availabilityNote: String?

    /// A11Y (audit-v0162 §5) — gates the imperative scroll-into-view animation
    /// on selection change so the highlighted pill jumps instead of sliding when
    /// Reduce Motion is on (the `.hlAnimation` on the strip already honours it).
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollViewReader { proxy in
            // A single horizontal row: Übersicht · flat metrics · category MENU
            // pills (tap → native selection menu of the category's members) ·
            // special pages. Picking a menu member drives the pager via
            // `selectPill`; the contiguous swipe order is owned by the pager and
            // untouched here.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: HLSpace.sm) {
                    ForEach(stripEntries, id: \.self) { entry in
                        stripPill(for: entry)
                            .id(scrollAnchor(for: entry))
                    }
                    if let onCustomize {
                        customizePill(action: onCustomize)
                    }
                    if let availabilityNote {
                        Text(availabilityNote)
                            .font(.hlSubhead)
                            .foregroundStyle(HLText.secondary)
                            // Single line by construction: this rides the pills'
                            // row and may never be the thing that makes it taller.
                            .lineLimit(1)
                            .padding(.horizontal, HLSpace.md)
                            .padding(.vertical, HLSpace.sm)
                    }
                }
                .padding(.horizontal, HLSpace.lg)
                .padding(.vertical, HLSpace.sm)
            }
            .scrollClipDisabled()
            // W29 — when a SWIPE moves the selection, scroll the matching pill into
            // view so the strip's highlighted pill never drifts off-screen.
            //
            // v0153 I2 — `anchor: nil` (minimal scroll to make the pill visible)
            // REPLACES the old `.leading` yank. With the pager now
            // category-contiguous the active member's owning-category pill no longer
            // sits at the far left of the strip, so left-aligning it teleported the
            // strip back to "Vitalwerte" on every later-member swipe (the operator's
            // "thrown back" bug). A minimal scroll only nudges when the pill is
            // genuinely off-screen and never yanks an already-visible pill leftward.
            .onChange(of: selection) { _, newValue in
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) {
                    proxy.scrollTo(scrollAnchor(forSelection: newValue), anchor: nil)
                }
            }
        }
        .hlAnimation(.easeInOut(duration: 0.22), value: selection)
        // W22-audit Finding #6 — expose the strip as one container of pills so
        // VoiceOver groups them as a navigable set (the iOS-idiomatic stand-in
        // for the web tablist role). The pills keep their `.isSelected`/`.isButton`
        // traits; `.contain` just gives the group a single accessible boundary.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("insights.tabStrip")
    }

    /// Q-insights-scroll — the single entry point for a pill tap. Always reports
    /// the tap up via `onPillTap` (so a re-tap of the active page can animate it
    /// to the top), THEN sets `selection`. The order matters: `onPillTap` fires
    /// even when the value is unchanged (a re-tap), whereas the `selection` write
    /// no-ops in that case. A first-time selection both reports AND switches.
    private func selectPill(_ sel: InsightsTabSelection) {
        onPillTap(sel)
        selection = sel
    }

    /// W28 / v0152 I1 — the strip render model: Übersicht + flat pills + category
    /// pills, derived from `orderedSelections`. The swipe order (the flat pager)
    /// stays the flat `orderedSelections`; this only changes which PILLS render
    /// (a multi-member category folds to one category pill).
    private var stripEntries: [InsightsStripEntry] {
        InsightsStripEntry.strip(from: orderedSelections)
    }

    /// Renders one strip entry: Übersicht / a flat metric pill / a special pill /
    /// a category pill (a native selection `Menu` over the category's members).
    @ViewBuilder
    private func stripPill(for entry: InsightsStripEntry) -> some View {
        switch entry {
        case .overview:
            let sel = InsightsTabSelection.overview
            pill(
                title: sel.title,
                isSelected: selection == sel,
                identifier: sel.tabStripPillIdentifier
            ) { selectPill(sel) }
        case let .flat(kind):
            let sel = InsightsTabSelection.metric(kind)
            pill(
                title: sel.title,
                isSelected: selection == sel,
                identifier: sel.tabStripPillIdentifier
            ) { selectPill(sel) }
        case let .special(page):
            let sel = InsightsTabSelection.special(page)
            pill(
                title: sel.title,
                isSelected: selection == sel,
                identifier: sel.tabStripPillIdentifier
            ) { selectPill(sel) }
        case let .group(category, members):
            categoryPill(category, members: members)
        }
    }

    /// A category parent pill — a native SwiftUI `Menu` (monochrome, glass-free,
    /// VoiceOver- and reduce-motion-correct for free). Its label is the category
    /// name + a trailing `chevron.down`; its items are the available member
    /// metrics in flat-swipe order. Tapping an item calls `selectPill`, which
    /// drives the pager to that member's page (same jump a flat pill performs) —
    /// the operator's loved contiguous swipe stays entirely on the pager and is
    /// untouched. The native menu replaces the rejected v0153 downward accordion.
    ///
    /// The pill carries the SELECTED treatment when the current `selection` is one
    /// of this category's members (web `isGroupActive`), so the operator always
    /// sees which category the visible page lives in. A `.group` strip entry has
    /// ≥2 members (a 1-member category folds to `.flat` upstream), so there is
    /// never a one-item menu — single-member categories render as plain pills.
    @ViewBuilder
    private func categoryPill(
        _ category: InsightsMetricCategory,
        members: [InsightsTabSelection]
    ) -> some View {
        if !members.isEmpty {
            let isActive = isCategoryActive(category)
            Menu {
                ForEach(members, id: \.self) { member in
                    Button {
                        selectPill(member)
                    } label: {
                        if selection == member {
                            Label(member.title, systemImage: "checkmark")
                        } else {
                            Text(member.title)
                        }
                    }
                }
            } label: {
                HStack(spacing: HLSpace.xs) {
                    Text(category.label)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Image(systemName: "chevron.down")
                        .font(.hlCaption.weight(.semibold))
                }
                .font(.hlSubhead.weight(.semibold))
                .foregroundStyle(isActive ? HLSurface.primary : HLText.secondary)
                .padding(.horizontal, HLSpace.md)
                .padding(.vertical, HLSpace.sm)
                .background {
                    Capsule(style: .continuous)
                        .fill(isActive ? AnyShapeStyle(HLText.primary) : AnyShapeStyle(HLSurface.tertiary))
                }
                .overlay {
                    if !isActive {
                        Capsule(style: .continuous)
                            .strokeBorder(HLText.tertiary.opacity(0.35), lineWidth: 1)
                    }
                }
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .sensoryFeedback(.selection, trigger: isActive)
            .accessibilityIdentifier(category.tabStripPillIdentifier)
            .accessibilityLabel(category.label)
            // A Menu already exposes its button/menu role to VoiceOver; carry the
            // selected treatment through as a trait so the active category reads as
            // selected, mirroring the flat pills.
            .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
        }
    }

    /// True when the current selection belongs to `category` — drives the category
    /// pill's active treatment + scroll-into-view anchoring. Parity 4.4 — resolved
    /// over the whole selection, so the Aktivität pill also lights up on the
    /// `workouts` special page now that it is one of that category's members.
    private func isCategoryActive(_ category: InsightsMetricCategory) -> Bool {
        InsightsCategoryGroups.category(for: selection) == category
    }

    /// The scroll anchor `id` for a rendered strip entry. A flat pill anchors on
    /// its own `InsightsTabSelection`; a category pill anchors on a stable
    /// per-category token so a member-page selection can scroll the PARENT pill
    /// into view (the member itself has no pill of its own).
    private func scrollAnchor(for entry: InsightsStripEntry) -> InsightsStripAnchor {
        switch entry {
        case .overview: .selection(.overview)
        case let .flat(kind): .selection(.metric(kind))
        case let .special(page): .selection(.special(page))
        case let .group(category, _): .category(category)
        }
    }

    /// The scroll anchor matching the CURRENT selection: a grouped member resolves
    /// to its category's parent-pill anchor, everything else to its own pill.
    private func scrollAnchor(forSelection selection: InsightsTabSelection) -> InsightsStripAnchor {
        if let category = InsightsCategoryGroups.category(for: selection) {
            return .category(category)
        }
        return .selection(selection)
    }
}

// MARK: - Selection model

/// v0.11 W28c — the three **special** Insights pages (web `/insights/mood`,
/// `/insights/medications`, `/insights/workouts`). Unlike a metric page these are
/// composite surfaces driven by `MoodStore` / `MedicationsStore` / `WorkoutsStore`
/// (mood = score + stability + patterns; medications = per-med adherence; workouts
/// = recent-workout list), so they have no single chartable `MetricKind`. They map
/// to their own layout slugs (`mood` / `medications` / `workouts`), already part of
/// `InsightsLayoutTileId.serverKnownIds`, so the server layout order curates their
/// strip position alongside the metric pills.
enum InsightsSpecialPage: String, Hashable, CaseIterable {
    case mood
    case medications
    case workouts
    /// W-B189 (#23) — the server-computed recovery sub-page (strain /
    /// training-load / autonomic-charge + the daily heart-and-energy family).
    /// Like the other specials it is a composite surface (driven by
    /// `RecoveryInsightsStore`), not a single chartable `MetricKind`.
    case recovery
    /// v0141 W-PARITY (P8) — the ECG recording surface (web `/insights/ecg`,
    /// server v1.28.50). Composite like its siblings: ECG has no
    /// `MeasurementType` and therefore no chartable `MetricKind`, so it is a
    /// page driven by `EcgStore` rather than a metric pill. **Data-gated on
    /// `EcgStore.hasRecordings`** — an account with no recordings sees no pill
    /// at all, exactly as the web gates it (`insights-tab-strip.tsx:588`).
    case ecg

    /// The English-canonical `InsightsLayoutTileId` slug this page maps to.
    var slug: String {
        switch self {
        case .mood: InsightsLayoutTileId.mood
        case .medications: InsightsLayoutTileId.medications
        case .workouts: InsightsLayoutTileId.workouts
        case .recovery: InsightsLayoutTileId.recovery
        case .ecg: InsightsLayoutTileId.ecg
        }
    }

    /// The special page for a layout slug, or `nil` for any non-special slug.
    static func page(forSlug slug: String) -> InsightsSpecialPage? {
        let normalized = InsightsLayoutTileId.normalize(slug)
        return allCases.first { $0.slug == normalized }
    }

    /// #30 — the server feature-module this special page belongs to, or `nil` for
    /// a core / never-gated page. When the owning module is OFF the page is
    /// dropped from the strip + pager.
    ///
    /// Build 2 / 2.6: `medications` used to return `nil` here on the (then-true)
    /// assumption that it was CORE. The server made it a real toggle (registry
    /// D3 / web v1.18.1), so the page now gates like its siblings — otherwise a
    /// user who switched Medications off still saw its Insights page.
    var moduleKey: ModuleKey? {
        switch self {
        case .mood: .mood
        case .workouts: .workouts
        case .recovery: .recovery
        case .medications: .medications
        // P8 — the ECG routes are gated on the `insights` module server-side
        // (plus the `insightStatus` assistant surface, which the repository's
        // 403 arm handles), so the pill disappears with the module.
        case .ecg: .insights
        }
    }

    /// The localized pill / page title (reuses the existing web-parity nav keys).
    var title: String {
        switch self {
        case .mood: String(localized: "Mood")
        case .medications: String(localized: "Medications")
        case .workouts: String(localized: "Workouts")
        case .recovery: String(localized: "Recovery")
        case .ecg: String(localized: "insights.ecg.title")
        }
    }
}

/// What the Insights tab strip currently has selected — the Übersicht surface,
/// one metric's detail, or one of the three special composite pages. Drives both
/// the strip's selected-pill treatment and the container's content switch.
enum InsightsTabSelection: Hashable {
    case overview
    case metric(MetricKind)
    /// v0.11 W28c — a composite special page (mood / medications / workouts).
    case special(InsightsSpecialPage)

    /// The localized pill / page title.
    var title: String {
        switch self {
        case .overview: String(localized: "Overview")
        case let .metric(kind): kind.displayName
        case let .special(page): page.title
        }
    }

    /// Stable UI-test identifier for the strip pill.
    var tabStripPillIdentifier: String {
        switch self {
        case .overview: "insights.tabStrip.pill.overview"
        case let .metric(kind): "insights.tabStrip.pill.\(kind.rawValue)"
        case let .special(page): "insights.tabStrip.pill.\(page.rawValue)"
        }
    }

    /// The full ordered tab list — Übersicht first, then the availability-gated
    /// metric AND special selections in the server layout order. W29: the SINGLE
    /// source of truth shared by the tab strip (pill order) and the container's
    /// swipe pager (page order), so the highlighted pill and the visible page stay
    /// in lockstep.
    ///
    /// W28c — the three special slugs (`mood` / `medications` / `workouts`) now
    /// resolve to a `.special` page when the operator HAS data for them
    /// (`availableSpecials`), placed at their server-layout slot exactly like a
    /// metric pill. A special with no data is skipped (Doctrine: never a dead
    /// pill — the surface self-suppresses rather than showing an empty box).
    ///
    /// Parity Build 4 — `recovery` is the one exception: it is a FIXED second
    /// entry (see below), and the returned order is otherwise the operator's
    /// curated layout order verbatim, with no category re-sort and no appends.
    static func ordered(
        layout: InsightsLayout,
        availableKinds: Set<MetricKind>,
        availableSpecials: Set<InsightsSpecialPage> = []
    ) -> [InsightsTabSelection] {
        var entries: [InsightsTabSelection] = [.overview]
        var placedSpecials: Set<InsightsSpecialPage> = []
        // Parity Build 4 / 4.4 — Recovery is a FIXED second pill, immediately
        // after Übersicht, not a tail-append. The web pushes it as a hard-coded
        // strip entry right after Overview and gates it ONLY on the `recovery`
        // module toggle — never on data (`insights-tab-strip.tsx:534-547`: "it has
        // no `summaries[METRIC].count` to gate on — the page data-gates every
        // block and falls back to a calm empty note"). `availableSpecials` now
        // carries `.recovery` whenever the module is on (the `hasContent` data
        // gate was dropped in `InsightsContainerScreen+Ordering`), so this
        // placement is the whole gate.
        if availableSpecials.contains(.recovery) {
            entries.append(.special(.recovery))
            placedSpecials.insert(.recovery)
        }
        for tile in layout.visibleTiles {
            if let kind = InsightsTabSlug.metricKind(forSlug: tile.id) {
                guard availableKinds.contains(kind) else { continue }
                entries.append(.metric(kind))
            } else if let page = InsightsSpecialPage.page(forSlug: tile.id) {
                guard availableSpecials.contains(page),
                      !placedSpecials.contains(page) else { continue }
                entries.append(.special(page))
                placedSpecials.insert(page)
            }
        }
        // P8 (v0141 parity) — ECG is NOT a server layout tile (see
        // `InsightsLayoutTileId.ecg`), so it can never arrive through
        // `visibleTiles`. It is appended here, AFTER the layout order, and the
        // category fold below then pulls it into the Heart block at that
        // category's first slot — which is exactly what the web does: the ECG
        // entry is injected into the Heart group's popover rather than ordered
        // as a metric (`insights-tab-strip.tsx:176-181, 588`). With no heart
        // metric available at all it stays at the tail as its own Heart pill
        // (web `:614` emits the group for ECG alone in the same case).
        // `availableSpecials` carries `.ecg` only when the operator HAS
        // recordings AND the `insights` module is on — the whole gate.
        if availableSpecials.contains(.ecg), !placedSpecials.contains(.ecg) {
            entries.append(.special(.ecg))
            placedSpecials.insert(.ecg)
        }
        // Parity Build 4 / 4.1 — the `recovery` and `steps` tail-appends are both
        // GONE. Recovery is now placed as the fixed second pill above (web
        // parity); `steps` is a first-class server layout slug (it entered
        // `SUB_PAGE_METRIC` in web v1.12 and the server's resolver auto-merges it
        // onto older saved layouts), so it arrives through `visibleTiles` at its
        // curated position like every other metric.
        //
        // v0153 restored (`c8f1aa3b` reverted it → the swipe-order regression came
        // back): make the order CATEGORY-CONTIGUOUS as the LAST step. This is the
        // single production entry point from which the live list, the frozen
        // `pagerOrder`, the strip fold, and the pager pages all derive, so folding
        // here (and ONLY here) keeps them in lockstep — pill N ↔ page N, one swipe
        // = one step. It is NOT a re-sort of the server layout: the strip folds each
        // category to ONE pill at its first member's slot regardless, so the Web-
        // paritätische Pill-Slots stay identical (no PUT, no server write) — only
        // the iOS swipe TRAVERSAL (which the web has no equivalent of) becomes
        // block-contiguous. Do NOT remove this again as "non-parity": the raw layout
        // order scatters a category's members (e.g. vitals' oxygen/active-energy/
        // resting-pulse between Gewicht/BMI/Schlaf), so a swipe through "Vitalwerte"
        // jumps ~3 pills out then back. The invariant + monotone-walk tests guard it.
        return categoryContiguous(entries)
    }

    /// v0153 restored + Parity 4.4 widened — a PURE reorder of an ordered selection
    /// list that pulls every category's members to sit immediately after that
    /// category's FIRST member, while leaving Übersicht, flat (ungrouped) metrics,
    /// and ungrouped/pinned special pages at their original slots. The category
    /// SEQUENCE is preserved (anchored on each category's first appearance in the
    /// input, i.e. the operator's curated order between categories) — only the
    /// *interleaving* is removed.
    ///
    /// Widened vs. the original v0153 pass (which clustered only `.metric`): members
    /// are whole `InsightsTabSelection`s keyed via
    /// `InsightsCategoryGroups.category(for:)`, so a grouped special page
    /// (`.special(.workouts)` → Aktivität, a member since Parity 4.4) clusters into
    /// its category block alongside the chartable activity metrics — mirroring the
    /// strip fold, which groups by the very same lookup. `.overview`, pinned/flat
    /// metrics, and `.special(.recovery)`/mood/medications (category == nil) keep
    /// their slots verbatim.
    ///
    /// Deterministic + idempotent: running it again yields the same list (members
    /// are already contiguous after the first pass). `nonisolated static` so the
    /// unit tests can drive it without a view.
    nonisolated static func categoryContiguous(
        _ entries: [InsightsTabSelection]
    ) -> [InsightsTabSelection] {
        // Members per category, in first-seen (flat-swipe) order.
        var membersByCategory: [InsightsMetricCategory: [InsightsTabSelection]] = [:]
        for selection in entries {
            if let category = InsightsCategoryGroups.category(for: selection) {
                membersByCategory[category, default: []].append(selection)
            }
        }
        var result: [InsightsTabSelection] = []
        var emittedCategories: Set<InsightsMetricCategory> = []
        for entry in entries {
            guard let category = InsightsCategoryGroups.category(for: entry) else {
                // Übersicht / flat metric / pinned-or-ungrouped special — keep its
                // slot verbatim.
                result.append(entry)
                continue
            }
            // A grouped member: emit the WHOLE category's members the first time we
            // reach any of them (at this first member's slot), then skip the later
            // scattered members entirely (they were just pulled forward here).
            guard !emittedCategories.contains(category) else { continue }
            emittedCategories.insert(category)
            result.append(contentsOf: membersByCategory[category] ?? [])
        }
        return result
    }
}

// MARK: - Slug ↔ MetricKind table

/// The EN-canonical Insights layout slug ↔ `MetricKind` mapping (mirror of the
/// web `SUB_PAGE_METRIC` table, `insights-tab-strip.tsx:114-246`). The slug
/// vocabulary is the same English-canonical set `InsightsLayoutTileId` already
/// owns (`blood-pressure`, `pulse`, `weight`, …); this maps the chartable subset
/// onto the iOS `MetricKind` enum so the strip can build a per-metric pill from
/// the server layout order.
///
/// v0.11 W28b — widened to the full chartable metric universe the server's
/// layout enum now accepts (`v0.11-server-to-ios-insights-layout-enum-
/// WIDENED.md`). Every slug below maps to a `MetricKind` that already exists in
/// the enum and already carries assessment wiring (W28a); the strip still gates
/// each pill on ≥1 measurement, so adding ids never produces a dead pill.
///
/// Slugs WITHOUT a single chartable `MetricKind` are intentionally absent:
/// - `overview` — the Übersicht pill, not a metric.
/// - `workouts` — a workout list, no single metric series.
/// - `mood` — two half-metrics (score / stability), no single chart kind.
/// - `medications` — adherence, not a measurement series.
/// - `audio-events` — no chartable `MetricKind` (`audioExposureEvent` is a
///   HealthKit CATEGORY / event-marker type, not a continuous quantity series;
///   forcing it into the chartable model would be wrong — see W28d report. If
///   ever surfaced it belongs as an event-COUNT, not a line chart).
///
/// `walking-steadiness` DOES map now (W28d): `appleWalkingSteadiness` is a clean
/// 0–100 % mobility quantity, wired into the HK registry + `slugToKind` below.
///
/// These render no metric pill (web shows them as group/flat non-chart entries);
/// every pill that renders routes to a working `ChartDetailScreen`, so there are
/// no dead pills.
enum InsightsTabSlug {
    /// The chartable `MetricKind` for a layout slug, or `nil` for non-chart slugs
    /// (`overview`, `workouts`, `mood`, `medications`, or any unknown id).
    ///
    /// W-WIDGET-DEEPLINK (v0152) — the canonical slug ⇄ kind table now lives on
    /// the plattform-free `InsightsLayoutTileId` (compiled into the widget
    /// extension too) so the `LatestMeasurement` widget can build a per-metric
    /// deep link. This app-only wrapper delegates to it (normalising legacy
    /// German aliases first), keeping every existing call site unchanged.
    static func metricKind(forSlug slug: String) -> MetricKind? {
        InsightsLayoutTileId.kind(forSlug: slug)
    }

    /// v0.13.1 IC — the layout slug for a chartable `MetricKind` (reverse of
    /// `slugToKind`), or `nil` for a kind with no Insights slug. Used by the
    /// Dashboard tile tap to feed the `AppRouter.selectInsightsMetric(_:)` deep
    /// link so a tap lands the operator IN the Insights tab on that metric's
    /// page (instead of pushing a duplicate-feeling detail onto the Home stack).
    static func slug(forKind kind: MetricKind) -> String? {
        InsightsLayoutTileId.slug(forKind: kind)
    }

    /// Every chartable layout slug (the `slugToKind` key set). Used by
    /// `InsightsCategoryGroups` to build the reverse kind→slug map for category
    /// resolution. Order is unspecified (the strip orders by layout, not this).
    static var allChartableSlugs: [String] {
        Array(InsightsLayoutTileId.slugToKind.keys)
    }
}
