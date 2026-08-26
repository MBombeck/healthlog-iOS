import Foundation

/// v0.11 W28 — the Insights tab-strip **category grouping** (web parity).
///
/// The web app folds its 24+ secondary metric pills behind **7 category
/// popovers** so the strip stays scannable (`SUB_PAGE_GROUP` /
/// `SUB_PAGE_GROUP_META`, `src/lib/insights/sub-page-metric.ts:147-197`,
/// `insights-tab-strip.tsx:286-378`). This type mirrors that taxonomy on iOS:
/// it maps each grouped layout slug → its category, defines the category order +
/// member order, and carries the localized parent-pill label.
///
/// **Presentation only — the swipe order is untouched.** The horizontal pager in
/// `InsightsContainerScreen` keeps paging the FLAT `InsightsTabSelection.ordered`
/// list (every available metric, in server-layout order). This grouping changes
/// ONLY the *strip pills*: a category renders one `Menu` parent pill (instead of
/// N flat pills) whose items jump the pager to a member's page. The page sequence
/// — and the left/right swipe traversal — is identical to before grouping. This
/// is the exact `buildTabs` vs `SUB_PAGE_SLUGS` split the web uses
/// (`SUB_PAGE_GROUP` is a strip-presentation bucket, never the page order).
///
/// **Flat pills stay flat.** The web keeps a short PINNED set as direct entries —
/// `blood-pressure · weight · sleep · medications · mood`
/// (`PINNED_SUB_PAGE_SLUGS`, `sub-page-metric.ts:187-193`). Any slug WITHOUT a
/// `category(forSlug:)` entry renders as a direct pill exactly as today.
enum InsightsMetricCategory: String, CaseIterable, Hashable {
    case vitals
    case body
    case activity
    /// Parity Build 4 / 4.1 — renamed from `cardiovascular` and widened to the
    /// web's `heart` group (2026-07-17 UX/IA audit H2, `sub-page-metric.ts:218-231`):
    /// pulse / resting-pulse / HRV moved in from `vitals` (and `pulse` lost its
    /// flat status), joining the three Withings vascular markers that were all the
    /// old `cardiovascular` bucket ever held.
    case heart
    case hearing
    case environment
    case metabolic

    /// The localized parent-pill label (mirror web `*Parent.label`). `Vitals` and
    /// `Environment` reuse existing xcstrings keys; the rest are appended.
    var label: String {
        switch self {
        case .vitals: String(localized: "Vitals")
        case .body: String(localized: "Body")
        case .activity: String(localized: "Activity")
        case .heart: String(localized: "Heart")
        case .hearing: String(localized: "Hearing")
        case .environment: String(localized: "Environment")
        case .metabolic: String(localized: "Metabolic")
        }
    }

    /// Stable UI-test identifier for the category's parent `Menu` pill.
    var tabStripPillIdentifier: String {
        "insights.tabStrip.pill.group.\(rawValue)"
    }
}

/// The slug-grouping taxonomy + the strip-render-model builder.
///
/// **Parity Build 4 / 4.1 — this is now a 1:1 mirror of the web `SUB_PAGE_GROUP`
/// (`src/lib/insights/sub-page-metric.ts:195-256`) plus `PINNED_SUB_PAGE_SLUGS`.**
/// The three standing b215/v0.13.1 divergences were resolved in favour of web
/// parity by operator decision:
///
/// - `skin-temperature` / `wrist-temperature` move **vitals → metabolic**. The
///   b215 rationale (a lone metabolic member would collapse to a standalone
///   "Hauttemperatur" pill) is now moot: metabolic carries three members, so it
///   renders as a real popover whether or not the operator has glucose data.
/// - `active-energy` moves **vitals → activity**, `bmi` **flat → body**,
///   `breathing-disturbances` **vitals → flat** (the web deliberately leaves it
///   ungrouped), `steps` keeps its activity home — which the web now shares
///   (`steps` became a `SUB_PAGE_METRIC` key in v1.12, so the old "the web has no
///   steps subpage" note here was stale).
/// - `cardiovascular` → ``InsightsMetricCategory/heart``, absorbing `pulse` /
///   `resting-pulse` / `hrv`.
///
/// Slugs the web groups but iOS has no `MetricKind` for (`audio-events`) are
/// absent here too — they map to no pill anyway
/// (`InsightsTabSlug.metricKind` returns `nil`), so they never widen a menu.
enum InsightsCategoryGroups {
    /// Parity Build 4 / 4.1 — the web `PINNED_SUB_PAGE_SLUGS` (2026-07-17 UX/IA
    /// audit H2, `sub-page-metric.ts:187-193`): the account's highest-traffic
    /// pages, which always render as their own flat pill even if they carry a
    /// ``slugToCategory`` entry, and are excluded from that category's menu so
    /// they never appear twice.
    ///
    /// iOS pinned three too many before this build (`pulse`, `bmi` and the
    /// `workouts` special were flat by accident of history, not by intent);
    /// each has moved into its web group and the set is now exactly the web five.
    static let pinnedSlugs: Set<String> = [
        InsightsLayoutTileId.bloodPressure,
        InsightsLayoutTileId.weight,
        InsightsLayoutTileId.sleep,
        InsightsLayoutTileId.medications,
        InsightsLayoutTileId.mood
    ]

    /// Grouped layout-slug → category. Keys are `InsightsLayoutTileId` constants.
    /// The full set of grouped slugs; everything else is a flat pill.
    static let slugToCategory: [String: InsightsMetricCategory] = [
        // vitals — `sub-page-metric.ts:197-199` + the v1.25 `pain` addition.
        InsightsLayoutTileId.oxygen: .vitals,
        InsightsLayoutTileId.bodyTemperature: .vitals,
        InsightsLayoutTileId.respiratoryRate: .vitals,
        // Parity 4.1 — patient-reported physiological signal; web rides it in the
        // vitals popover (`:253`). Previously slug-less, so its Dashboard tile
        // was a dead tap.
        InsightsLayoutTileId.pain: .vitals,
        // body composition — `:201-208` + the v1.25 waist pair (`:254-255`).
        InsightsLayoutTileId.bmi: .body,
        InsightsLayoutTileId.bodyWater: .body,
        InsightsLayoutTileId.boneMass: .body,
        InsightsLayoutTileId.fatFreeMass: .body,
        InsightsLayoutTileId.fatMass: .body,
        InsightsLayoutTileId.muscleMass: .body,
        InsightsLayoutTileId.visceralFat: .body,
        InsightsLayoutTileId.leanBodyMass: .body,
        InsightsLayoutTileId.waist: .body,
        InsightsLayoutTileId.waistToHeight: .body,
        // activity / mobility — `:210-213` + `:243-256`.
        InsightsLayoutTileId.steps: .activity,
        InsightsLayoutTileId.activeEnergy: .activity,
        // Parity 4.4 — `workouts` is a SPECIAL page on iOS (no chartable kind),
        // but the web folds it into the activity popover like any other member
        // (`:213`), so it is grouped here and the strip builder folds specials
        // that carry a category. Resolved via `category(for page:)`.
        InsightsLayoutTileId.workouts: .activity,
        InsightsLayoutTileId.flightsClimbed: .activity,
        InsightsLayoutTileId.walkingDistance: .activity,
        InsightsLayoutTileId.walkingSteadiness: .activity,
        InsightsLayoutTileId.walkingHeartRate: .activity,
        InsightsLayoutTileId.walkingAsymmetry: .activity,
        InsightsLayoutTileId.doubleSupportTime: .activity,
        InsightsLayoutTileId.stepLength: .activity,
        InsightsLayoutTileId.walkingSpeed: .activity,
        InsightsLayoutTileId.cardioFitness: .activity,
        InsightsLayoutTileId.falls: .activity,
        InsightsLayoutTileId.sixMinuteWalk: .activity,
        InsightsLayoutTileId.stairAscentSpeed: .activity,
        InsightsLayoutTileId.stairDescentSpeed: .activity,
        InsightsLayoutTileId.gripStrength: .activity,
        // heart — `:218-231`. `pulse` / `resting-pulse` / `hrv` joined the three
        // vascular markers here in the 2026-07-17 UX/IA audit.
        InsightsLayoutTileId.pulse: .heart,
        InsightsLayoutTileId.restingPulse: .heart,
        InsightsLayoutTileId.hrv: .heart,
        InsightsLayoutTileId.pulseWaveVelocity: .heart,
        InsightsLayoutTileId.vascularAge: .heart,
        InsightsLayoutTileId.cardioRecovery: .heart,
        // hearing — `:233-235`. `audio-events` is omitted: no iOS `MetricKind`.
        InsightsLayoutTileId.environmentalAudio: .hearing,
        InsightsLayoutTileId.headphoneAudio: .hearing,
        // environment — `:237`.
        InsightsLayoutTileId.daylight: .environment,
        // metabolic — `:239-240,249`. Skin + wrist temperature live here on the
        // web; the b215 divergence that parked them in vitals is resolved.
        InsightsLayoutTileId.bloodGlucose: .metabolic,
        InsightsLayoutTileId.skinTemperature: .metabolic,
        InsightsLayoutTileId.wristTemperature: .metabolic
        // `breathing-disturbances` is deliberately ABSENT — the web leaves it
        // ungrouped (no `SUB_PAGE_GROUP` entry), so it renders as a flat pill.
    ]

    /// The category for a layout slug, honouring the pinned override: a pinned
    /// slug is always flat, whatever ``slugToCategory`` says. (Today the two sets
    /// are disjoint, exactly as on the web; the guard keeps them that way by
    /// construction rather than by coincidence.)
    static func category(forSlug slug: String) -> InsightsMetricCategory? {
        guard !pinnedSlugs.contains(slug) else { return nil }
        return slugToCategory[slug]
    }

    /// The category a grouped `MetricKind` belongs to (via its layout slug), or
    /// `nil` for a flat (ungrouped) metric. Resolved through the chartable
    /// slug↔kind table so the lookup is keyed on the same vocabulary the pager
    /// uses.
    static func category(for kind: MetricKind) -> InsightsMetricCategory? {
        guard let slug = slugForKind[kind] else { return nil }
        return category(forSlug: slug)
    }

    /// Parity 4.4 — the category a **special** page folds into, or `nil` when it
    /// stays a flat pill. Only `workouts` is grouped (into activity, web `:213`);
    /// `mood`/`medications` are pinned and `recovery` is the fixed second pill.
    static func category(for page: InsightsSpecialPage) -> InsightsMetricCategory? {
        guard page != .recovery else { return nil }
        // P8 (v0141 parity) — ECG folds into the HEART group, but deliberately
        // NOT via `slugToCategory`: the web keeps `ecg` out of `SUB_PAGE_GROUP`
        // entirely (it carries no `MeasurementType`) and injects it into the
        // Heart popover as a non-slug child instead
        // (`insights-tab-strip.tsx:172-181, 588`). Mirroring that here keeps the
        // slug map a verbatim mirror of the web's, and keeps `ecg` out of
        // `serverKnownIds` — where it would 422 a layout PUT.
        if page == .ecg { return .heart }
        return category(forSlug: page.slug)
    }

    /// The category owning a whole strip/pager selection — the one lookup the
    /// strip needs now that a special page can be a group member too.
    static func category(for selection: InsightsTabSelection) -> InsightsMetricCategory? {
        switch selection {
        case .overview: nil
        case let .metric(kind): category(for: kind)
        case let .special(page): category(for: page)
        }
    }

    /// Reverse of `InsightsTabSlug.slugToKind` — the layout slug for a chartable
    /// kind. Built once; used to resolve a kind's category and to order members.
    private static let slugForKind: [MetricKind: String] = {
        var map: [MetricKind: String] = [:]
        for slug in InsightsTabSlug.allChartableSlugs {
            if let kind = InsightsTabSlug.metricKind(forSlug: slug) {
                map[kind] = slug
            }
        }
        return map
    }()
}

// MARK: - Strip render model

/// The `ScrollViewReader` anchor id for a rendered strip pill. A flat pill (or
/// Übersicht) anchors on its own selection; a category parent pill anchors on its
/// category — so a member-page selection (which has no pill of its own) resolves
/// to the parent pill it folds into for scroll-into-view.
enum InsightsStripAnchor: Hashable {
    case selection(InsightsTabSelection)
    case category(InsightsMetricCategory)
}

/// One rendered entry in the Insights tab strip — the strip-presentation model,
/// parallel to (and built FROM) the flat `InsightsTabSelection.ordered` swipe
/// list. The pager never sees this type; it exists purely so the strip can fold
/// grouped metrics behind one `Menu` pill while the swipe order stays flat.
///
/// Mirrors web `buildTabs` (`insights-tab-strip.tsx:320-378`): walk the flat
/// ordered selections; a flat metric (or Übersicht) emits a direct pill, and the
/// FIRST grouped member encountered emits the category's parent pill at that
/// position (later members of the same category fold in). So the strip order is
/// the flat order with each category collapsed at its first member's slot —
/// categorical order is preserved, exactly like web.
enum InsightsStripEntry: Hashable {
    /// The leading Übersicht pill (always first, never grouped).
    case overview
    /// A flat (ungrouped) metric pill — same treatment as today's pills.
    case flat(MetricKind)
    /// v0.11 W28c — a flat special-page pill (mood / medications / recovery).
    /// Parity 4.4 — `workouts` is no longer always flat: a special page that
    /// carries a category (`InsightsCategoryGroups.category(for page:)`) folds
    /// into that category's menu, mirroring the web, and only the ungrouped
    /// specials still emit a direct pill at their layout slot.
    case special(InsightsSpecialPage)
    /// A category parent pill: a `Menu` whose items are the available member
    /// selections, in flat-swipe order. Never empty (a 0-member category emits no
    /// entry). A 1-member category is rendered as a direct pill, not a menu
    /// (`prefer no 1-item menus` — operator doctrine), so this case always
    /// carries ≥2 members.
    ///
    /// Parity 4.4 — members are `InsightsTabSelection`, not `MetricKind`, so the
    /// `workouts` special page can sit inside the Aktivität menu alongside the
    /// chartable activity metrics exactly as the web renders it.
    case group(InsightsMetricCategory, members: [InsightsTabSelection])

    /// Builds the strip render model from the flat ordered swipe selections.
    ///
    /// - The Übersicht entry maps to `.overview`.
    /// - A metric with no category maps to `.flat(kind)`.
    /// - The first metric of a category emits `.group(category, members)` at that
    ///   slot, where `members` are that category's metrics IN FLAT ORDER that are
    ///   present in `ordered` (i.e. already availability-gated upstream). Later
    ///   members of the same category are skipped (folded into the parent).
    /// - A category that resolves to exactly ONE available member collapses to a
    ///   `.flat(member)` pill instead of a 1-item menu.
    ///
    /// Because `ordered` is already availability-gated, an empty category simply
    /// never appears here — no dead menu, matching the web `children.length === 0`
    /// guard and iOS's existing per-pill availability contract.
    static func strip(from ordered: [InsightsTabSelection]) -> [InsightsStripEntry] {
        // Members per category, in flat-swipe order, restricted to what's visible.
        var membersByCategory: [InsightsMetricCategory: [InsightsTabSelection]] = [:]
        for selection in ordered {
            if let category = InsightsCategoryGroups.category(for: selection) {
                membersByCategory[category, default: []].append(selection)
            }
        }

        var entries: [InsightsStripEntry] = []
        var emittedCategories: Set<InsightsMetricCategory> = []
        for entry in ordered {
            guard let category = InsightsCategoryGroups.category(for: entry) else {
                // Übersicht / pinned-or-ungrouped metric / ungrouped special —
                // a direct pill at its own slot, exactly as before.
                switch entry {
                case .overview: entries.append(.overview)
                case let .metric(kind): entries.append(.flat(kind))
                case let .special(page): entries.append(.special(page))
                }
                continue
            }
            // Emit the category parent at its FIRST member's slot only.
            guard !emittedCategories.contains(category) else { continue }
            emittedCategories.insert(category)
            let members = membersByCategory[category] ?? []
            if members.count <= 1 {
                // 1-member category → a plain pill (no 1-item menu).
                switch members.first {
                case .none, .overview: break
                case let .metric(kind): entries.append(.flat(kind))
                case let .special(page): entries.append(.special(page))
                }
            } else {
                entries.append(.group(category, members: members))
            }
        }
        return entries
    }
}

// MARK: - Pager page model (v0152 I1 — FLAT category-aware pager)

/// v0152 I1 (operator-confirmed reversal of the b198 grouped pager) — the FLAT
/// pager page model: **one page per metric**, in category order.
///
/// The b198/V0151 grouped pager made a category ONE swipe stop with an in-page
/// dropdown/second-pill-row member switch. The operator rejected it ("sieht total
/// bescheuert aus … bitte rausnehmen"). The replacement keeps the strip
/// CATEGORY-AWARE (a `Vitalwerte` pill that highlights for any vitals member) but
/// makes the PAGER a single continuous flat sequence over EVERY metric, ordered by
/// category (a category's members appear consecutively). Swiping walks the members
/// in order while the owning category pill stays highlighted; swiping past a
/// category's last member advances to the next pill's first metric.
///
/// The original b198 swipe-divergence (strip folded, pager flat → they disagreed)
/// is solved by deriving the active strip pill from the CURRENT metric's owning
/// category, so strip + pager agree over one flat sequence — without grouping.
///
/// So `InsightsPagerPage` is a thin 1:1 wrapper over `InsightsTabSelection`: every
/// selection is its own page. The strip's `InsightsStripEntry` fold (category
/// pills) is purely a presentation layer ON TOP of this flat sequence.
enum InsightsPagerPage: Hashable {
    /// The Übersicht page (always first).
    case overview
    /// A single metric page — one page per metric (flat, no grouping).
    case flat(MetricKind)
    /// A special composite page (mood / medications / workouts / recovery).
    case special(InsightsSpecialPage)

    /// The flat pager page list — one page per ordered selection, in the same
    /// category order the strip groups over. The pager `ForEach` iterates this;
    /// the strip `ForEach` iterates `InsightsStripEntry.strip(from:)` (which folds
    /// categories into pills over the SAME order). The active pill is derived from
    /// the current page's owning category, so the two never drift.
    static func pages(from ordered: [InsightsTabSelection]) -> [InsightsPagerPage] {
        ordered.map { selection in
            switch selection {
            case .overview: .overview
            case let .metric(kind): .flat(kind)
            case let .special(page): .special(page)
            }
        }
    }

    /// The page that hosts a given selection — a direct 1:1 match (the pager is
    /// flat). `nil` only when `pages` doesn't contain a page for the selection
    /// (its metric isn't currently available / visible).
    static func page(
        for selection: InsightsTabSelection,
        in pages: [InsightsPagerPage]
    ) -> InsightsPagerPage? {
        let target: InsightsPagerPage = switch selection {
        case .overview: .overview
        case let .metric(kind): .flat(kind)
        case let .special(page): .special(page)
        }
        return pages.first { $0 == target }
    }

    /// Stable identity used by the pager's `.scrollPosition(id:)` + `.id(_:)`. Each
    /// metric page has its own id, so a swipe between two members of the same
    /// category IS a page change (the flat-pager contract).
    var scrollIdentity: InsightsPagerPageID {
        switch self {
        case .overview: .overview
        case let .flat(kind): .metric(kind)
        case let .special(page): .special(page)
        }
    }
}

/// The pager's `.scrollPosition(id:)` token. Mirrors `InsightsTabSelection` 1:1
/// (the flat-pager contract — every metric is its own page, so the scroll id is
/// the metric itself, not a category bucket).
enum InsightsPagerPageID: Hashable {
    case overview
    case metric(MetricKind)
    case special(InsightsSpecialPage)
}
