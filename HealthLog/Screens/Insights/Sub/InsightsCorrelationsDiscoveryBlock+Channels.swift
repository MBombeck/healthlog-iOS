import Foundation

/// **The value half of the correlation-discovery block.**
///
/// Split out of `InsightsCorrelationsDiscoveryBlock.swift` on 2026-08-23 (Plan
/// 17-06), when C1's drill-in mapping pushed the view type past SwiftLint's
/// `type_body_length` ceiling. What moved is deliberately **values, not views**:
/// the curated channel table, the label resolvers, the Coach scope mapping and
/// C1's channel → Insights-page mapping are pure `nonisolated static` functions
/// with no SwiftUI in them at all, and the unit suites already address them
/// through the type name rather than through the rendering.
///
/// (Phase 15 lost a file split to the opposite choice — moving a VIEW carried an
/// `HLButton` legacy variant into a new file and moved a `UIStandardBaseline`
/// row with it. Nothing here matches any E5 rule pattern, so the ratchet is
/// untouched by construction.)
extension InsightsCorrelationsDiscoveryBlock {
    /// Stable VoiceOver state for the overview disclosure.
    nonisolated static func disclosureAccessibilityValue(
        isExpanded: Bool,
        locale: Locale = .current
    ) -> String {
        localized(isExpanded ? "Expanded" : "Collapsed", locale: locale)
    }

    /// Localized label per curated channel id (the EN source key doubles as the
    /// xcstrings lookup key). A flat table keeps this resolver linear; the
    /// catalog carries the EN + DE values.
    private nonisolated static let channelKeys: [String: String] = [
        "TIME_IN_DAYLIGHT": "time in daylight",
        "MOOD": "mood",
        "STEPS": "steps",
        "ACTIVE_ENERGY": "active energy",
        "EXERCISE_MINUTES": "exercise minutes",
        "STAND_HOURS": "stand hours",
        "SLEEP_DURATION": "sleep duration",
        "SLEEP_EFFICIENCY": "sleep efficiency",
        "RESTING_HEART_RATE": "resting heart rate",
        "HEART_RATE_VARIABILITY": "heart rate variability",
        "RESPIRATORY_RATE": "respiratory rate",
        "BODY_MASS": "body weight",
        "VO2_MAX": "cardio fitness",
        "MINDFUL_MINUTES": "mindful minutes",
        "CAFFEINE": "caffeine",
        "ALCOHOL": "alcohol",
        "WATER": "water intake"
    ]

    /// Human-readable label per curated channel id (behaviour OR outcome).
    /// Unknown ids fall back to a de-snaked form of the raw id so a later
    /// server channel still renders legibly (forward-compatible).
    nonisolated static func label(for channel: String, locale: Locale = .current) -> String {
        guard let key = channelKeys[channel] else { return prettify(channel) }
        return localized(key, locale: locale)
    }

    /// `SOME_CHANNEL` → `some channel` (forward-compatible fallback).
    nonisolated static func prettify(_ raw: String) -> String {
        raw.split(separator: "_")
            .map { $0.lowercased() }
            .joined(separator: " ")
    }

    // MARK: - CU-33, amended by C2/E6 — curated channels speak German first

    /// The behaviour channel's display name. **For a curated channel the local
    /// German table wins; for everything else the server's `behaviourLabel`
    /// still does.** See ``channelLabel(serverLabel:channel:locale:)`` for why
    /// the CU-33 precedence is inverted for exactly that set.
    nonisolated static func behaviourLabel(for pair: DiscoveredCorrelation) -> String {
        channelLabel(serverLabel: pair.behaviourLabel, channel: pair.behaviour)
    }

    /// The outcome channel's display name — same precedence as
    /// ``behaviourLabel(for:)``.
    nonisolated static func outcomeLabel(for pair: DiscoveredCorrelation) -> String {
        channelLabel(serverLabel: pair.outcomeLabel, channel: pair.outcome)
    }

    /// Resolves a channel's display name.
    ///
    /// **C2 / decision E6 (2026-08-23) — the CU-33 precedence is inverted for
    /// the curated set, and only for it.** CU-33 let the server's resolved label
    /// overrule the local table for two good reasons: it is the only thing that
    /// can name a channel the curated table has never heard of (a custom
    /// metric), and it is the wording the server's own `interpretation` prose
    /// uses, so headline and prose stayed in one voice.
    ///
    /// The first reason does not apply to the 17 curated channels — the app
    /// already owns their names, in German — and the second turned out to cost
    /// more than it bought: the server's label for a curated channel is an
    /// English token (`heart rate variability`), so the operator read English
    /// variable names in a German app and called them unusable. The local table
    /// therefore wins whenever ``channelKeys`` knows the channel.
    ///
    /// Everything outside that table keeps the server label unchanged. That
    /// boundary is load-bearing rather than cautious: a custom metric's name
    /// exists only server-side, the app has no translation for it and must not
    /// invent one, and its localization is the separately filed C2-Rest ask. An
    /// inversion applied one step wider would take away the only readable name
    /// those metrics have and make that ask incoherent.
    nonisolated static func channelLabel(
        serverLabel raw: String?,
        channel: String,
        locale: Locale = .current
    ) -> String {
        if channelKeys[channel] != nil {
            return label(for: channel, locale: locale)
        }
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return label(for: channel, locale: locale)
        }
        if trimmed.lowercased() == "environment: daylight" {
            return localized("Daylight", locale: locale)
        }
        return trimmed
    }

    /// Resolves a string-catalog key with the requested locale embedded in the
    /// resource. `String(localized:locale:)` only applies the locale while
    /// formatting and can otherwise inherit the process language in tests.
    private nonisolated static func localized(_ key: String, locale: Locale) -> String {
        String(
            localized: LocalizedStringResource(
                String.LocalizationValue(key),
                locale: locale
            )
        )
    }

    // MARK: - C1 — a row that looks pursuable is pursuable

    /// **C1 (walkthrough 2026-08-22: „es gibt weiterhin Einträge, denen man nicht
    /// weiter nachgehen kann")** — the Insights metric page a correlation channel
    /// drills into, or `nil` when the channel has no page of its own.
    ///
    /// „Navigable" is not a wish here, it is the router's own predicate.
    /// ``AppRouter/selectInsightsMetric(_:)`` lands on a real Insights page when
    /// `InsightsTabSlug.slug(forKind:)` resolves, and it special-cases `.mood`
    /// onto the Mood special page (b241 Fix 1 — mood rows are `MoodEntry`s, not
    /// `Measurement`s). Everything else degrades into the values table, which is
    /// a step sideways rather than a follow-up, so this table refuses to promise
    /// it: a channel is only listed when the tap lands where the pair's own claim
    /// can actually be examined.
    ///
    /// Deliberately narrower than ``scopeSource(forChannel:)``: the Coach can
    /// reason about a channel that has no page (mindful minutes, caffeine), a
    /// chevron cannot.
    nonisolated static func drillInKind(for channel: String) -> MetricKind? {
        guard let kind = drillInKinds[channel] else { return nil }
        guard kind == .mood || InsightsTabSlug.slug(forKind: kind) != nil else { return nil }
        return kind
    }

    /// Curated channel id → the metric page that explains it. Channels absent
    /// here have no page (`EXERCISE_MINUTES`, `STAND_HOURS`, `MINDFUL_MINUTES`,
    /// `CAFFEINE`, `ALCOHOL`, `WATER`) — and so does every custom metric, whose
    /// ids are not in the curated vocabulary at all.
    private nonisolated static let drillInKinds: [String: MetricKind] = [
        "MOOD": .mood,
        "STEPS": .steps,
        "ACTIVE_ENERGY": .activeEnergy,
        "TIME_IN_DAYLIGHT": .timeInDaylight,
        "SLEEP_DURATION": .sleep,
        "SLEEP_EFFICIENCY": .sleepEfficiency,
        "RESTING_HEART_RATE": .restingHeartRate,
        "HEART_RATE_VARIABILITY": .hrv,
        "RESPIRATORY_RATE": .respiratoryRate,
        "BODY_MASS": .weight,
        "VO2_MAX": .vo2Max
    ]

    /// The distinct metric pages a pair can be pursued into, behaviour first,
    /// de-duplicated (a `SLEEP_DURATION × SLEEP_EFFICIENCY` pair must not offer
    /// the same page twice). Empty is a legitimate answer and is exactly why the
    /// detail shape below exists for every pair rather than only for these.
    nonisolated static func drillIns(for pair: DiscoveredCorrelation) -> [MetricKind] {
        var kinds: [MetricKind] = []
        for channel in [pair.behaviour, pair.outcome] {
            guard let kind = drillInKind(for: channel), !kinds.contains(kind) else { continue }
            kinds.append(kind)
        }
        return kinds
    }

    /// **A360 H2 (v0156)** — collapse a discovered pair's two channel ids into a
    /// Coach launch scope spanning both, when at least the behaviour maps to a
    /// known scope source. Returns `nil` when neither channel maps (the Coach then
    /// opens against the default all-source snapshot rather than an empty scope).
    nonisolated static func launchScope(for pair: DiscoveredCorrelation) -> CoachLaunchScope? {
        let sources = [pair.behaviour, pair.outcome].compactMap(scopeSource(forChannel:))
        guard let primary = sources.first else { return nil }
        return CoachLaunchScope(metric: primary, also: Array(sources.dropFirst()))
    }

    /// Maps a server correlation channel id (`STEPS`, `MOOD`, …) to the Coach
    /// scope source token. `nil` for a channel the snapshot has no source for.
    nonisolated static func scopeSource(forChannel channel: String) -> CoachScopeSource? {
        switch channel {
        case "MOOD": .mood
        case "STEPS": .steps
        case "ACTIVE_ENERGY": .activeEnergy
        case "TIME_IN_DAYLIGHT": .daylight
        case "SLEEP_DURATION", "SLEEP_EFFICIENCY": .sleep
        case "RESTING_HEART_RATE": .restingHR
        case "HEART_RATE_VARIABILITY": .hrv
        case "RESPIRATORY_RATE": .respiratoryRate
        case "BODY_MASS": .weight
        case "VO2_MAX": .vo2Max
        default: nil
        }
    }
}
