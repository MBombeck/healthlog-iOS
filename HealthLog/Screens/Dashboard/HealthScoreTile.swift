import SwiftUI

/// Dashboard tile rendering the four-pillar Personal Health Score.
/// Tap → push the detail sheet with the provenance accordion.
///
/// iOS **renders only**. The score, band, delta, weights and component
/// `asOf` timestamps are server-derived; iOS never recomputes
/// (`16-health-score-logic.md §"Why iOS must not recompute…"`).
///
/// **Visual contract (F5/F6, v0.4.1):** mirrors the `ComplianceRingCard`
/// gold-standard layout from `DashboardScreen.swift` (the surface the
/// user explicitly called out as "vollkommen anders ... richtig
/// perfekt, richtig schick"). Same `HLCard` + ring-on-left +
/// HStack-padded-value-and-subtitle-on-right rhythm, so the two cards
/// stack cleanly above each other and read as one design system.
public struct HealthScoreTile: View {
    @Environment(HealthScoreStore.self) private var store
    /// R4 §3.1 — server-derived surface. When no backend is available the tile
    /// renders `HLCloudDerivedPlaceholder` instead of firing a doomed
    /// `/api/health-score` request. `hasServer` is always `true` in paired mode,
    /// so this gate is inert for paired users (no behaviour change).
    @Environment(BackendAvailability.self) private var backend
    /// v0.11 W3 — the shared "Server verbinden" CTA path. The placeholder's
    /// button calls `beginServerPairing()`, dropping the standalone user into
    /// the OnboardingFlow server branch with local data intact.
    @Environment(AuthStore.self) private var authStore
    @State private var detailPresented: Bool = false

    /// v0.5.4.2 — optional briefing-observation chip strip rendered below
    /// the ring/headline row. Carries 1-3 short observation headlines
    /// sourced from `DailyBriefingStore`'s `keyFindings`. Empty array
    /// (default) keeps the tile compact and back-compatible.
    private let observations: [String]

    public init(observations: [String] = []) {
        self.observations = observations
    }

    public var body: some View {
        if backend.canShowHealthScore {
            liveTile
        } else {
            // No backend → calm "connect a server" placeholder, never a doomed
            // request or a spinner that won't resolve.
            HLCloudDerivedPlaceholder(
                surfaceName: String(localized: "the Health Score"),
                onConnect: { authStore.beginServerPairing() }
            )
        }
    }

    private var liveTile: some View {
        Button {
            // PA4 #10: always allow tap — the detail sheet renders its own
            // empty + error states (e.g. server's `no_health_score` reply).
            // Pre-PB5 we disabled the button when `score == nil`, which hid
            // the explanatory copy from the user entirely.
            detailPresented = true
        } label: {
            HLCard {
                tileContent
            }
        }
        // W1-7: app-wide press-feedback
        .hlPressable()
        .task { if store.score == nil { await store.load() } }
        .sheet(isPresented: $detailPresented) {
            HealthScoreDetailSheet()
                .environment(store)
                // v0.6.1 Y2 — Home-Compliance pattern: drag-indicator is
                // the dismiss path; sheet opens at .medium and grows to
                // .large for the full provenance accordion.
                .hlSheetPresentation(.standard)
                .presentationBackground(HLColor.surface)
        }
    }

    @ViewBuilder
    private var tileContent: some View {
        if let score = store.score {
            HealthScoreLoaded(score: score, observations: observations)
        } else if store.isLoading {
            HealthScoreSkeleton()
        } else if let error = store.error {
            HealthScoreErrorState(error: error) {
                Task { await store.refresh() }
            }
        } else {
            HealthScoreSkeleton()
        }
    }
}

// MARK: - Loaded state

struct HealthScoreLoaded: View {
    let score: HealthScore
    var observations: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.md) {
            HStack(alignment: .center, spacing: HLSpace.lg) {
                HLRing(
                    progress: max(0, min(1, Double(score.score) / 100.0)),
                    label: String(localized: "of 100"),
                    value: "\(score.score)",
                    tint: bandColor
                )
                .frame(width: 92, height: 92)

                VStack(alignment: .leading, spacing: HLSpace.xs) {
                    captionRow
                    Text(headlineText)
                        .font(.hlTitle2)
                        .foregroundStyle(HLText.primary)
                        .monospacedDigit()
                    deltaSubtitle
                    // v1.18.3 — calm Rest Mode acknowledgement next to the score.
                    // Server-authoritative (`score.activeRestMode`) + gated on the
                    // illness module. Annotate-never-mutate: frames the number, never
                    // changes it. Self-suppresses when not in Rest Mode.
                    RestModeGate(score: score) { restMode in
                        RestModeAnnotationPill(restMode: restMode, style: .pill)
                            .padding(.top, HLSpace.xxs)
                    }
                }
                Spacer(minLength: 0)
            }
            // v0.5.4.2 — briefing observations merged into the tile.
            // Compact chip strip — 1 extra row max (truncates beyond 3).
            if !observations.isEmpty {
                HealthScoreObservationsStrip(observations: observations)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    /// **The caption line, plus the provenance mark when the composition was
    /// chosen (v1.35.0 / GH #83).**
    ///
    /// A 82 out of five self-chosen pillars is not the same statement as a 82
    /// out of eight, and this tile shows the number with nothing else to say so.
    /// The mark is Herkunft (R2) and nothing more — three words beside the
    /// caption, no explanation, no instruction. Server-resolved: it appears
    /// only when the server said `configured: true`.
    private var captionRow: some View {
        HStack(spacing: HLSpace.xs) {
            Text(String(localized: "Health Score"))
                .font(.hlCaption)
                .foregroundStyle(HLText.secondary)
            if score.runsOnChosenComposition {
                Text(verbatim: "·")
                    .font(.hlCaption)
                    .foregroundStyle(HLText.tertiary)
                    .accessibilityHidden(true)
                Text(verbatim: HealthScorePresentation.chosenCompositionMark)
                    .font(.hlCaption)
                    .foregroundStyle(HLText.tertiary)
                    .lineLimit(1)
            }
        }
    }

    /// Headline text — the qualitative band label only ("Grün" / "Gelb" /
    /// "Rot"). The numeric score lives **inside** the `HLRing` (large
    /// monospaced value) so duplicating it in the headline as "56 · Gelb"
    /// was a redundant double-read. Master-prompt v0.5.0+ R4 collapses to
    /// the canonical band-only headline; the ring stays the single source
    /// of the number. Localized "Health Score —" fallback when band is
    /// unknown (server returned a score without a banding classification).
    private var headlineText: String {
        bandLabel
    }

    /// The week-over-week line.
    ///
    /// **v1.34.0 — a withheld delta is explained, never dramatised.** When the
    /// server sets a `deltaReason` it also nulls the delta, and four of the six
    /// reasons mean *the measurement changed, not the person*
    /// (`algorithm_changed` above all). Those get the reason caption instead of
    /// a trend chip, so a formula change can never read as a health change.
    @ViewBuilder
    private var deltaSubtitle: some View {
        if let reason = score.deltaReason {
            Text(HealthScorePresentation.shortLabel(for: reason))
                .font(.hlCaption)
                .foregroundStyle(HLText.tertiary)
                .lineLimit(2)
        } else if let delta = score.narratableDelta {
            HStack(spacing: HLSpace.xs) {
                DeltaChip(delta: delta)
                Text(String(localized: "vs. last week"))
                    .font(.hlCaption)
                    .foregroundStyle(HLText.tertiary)
            }
        } else {
            Text(String(localized: "vs. last week —"))
                .font(.hlCaption)
                .foregroundStyle(HLText.tertiary)
        }
    }

    /// W-B187 / #27 — the tile colour follows the server-authoritative band token
    /// via ``HealthScore/displayBand``, falling back to the local numeric
    /// thresholds (green ≥67 / amber 34–66 / red ≤33) only when the server emits no
    /// band. The Dashboard tile and the Insights score surfaces now agree on the
    /// same green/yellow/red banding for a given score ("one engine"); the label
    /// stays consistent with the colour because both read `displayBand`.
    private var bandColor: Color {
        switch score.displayBand {
        case .green: HLColor.statusOK
        case .yellow: HLColor.statusWarn
        case .red: HLColor.statusBad
        }
    }

    private var bandLabel: String {
        switch score.displayBand {
        case .green: String(localized: "Green")
        case .yellow: String(localized: "Yellow", comment: "Health Score band label")
        case .red: String(localized: "Red", comment: "Health Score band label")
        }
    }

    private var accessibilityLabel: String {
        // v0.14.8 AUDIT-HOME L13b — speak the localized colour-band label
        // instead of interpolating the raw server `band` token (or the
        // hardcoded German "unbekannt") into the localized sentence.
        // v1.34.0 — a suppressed delta speaks its reason, not a fake "—".
        // v1.35.0 — and it speaks the provenance mark the tile paints, so the
        // spoken tile carries the same statement the seen one does.
        let base: String
        if let reason = score.deltaReason {
            base = String(
                localized: "Health Score \(score.score) of 100, band \(bandLabel). \(HealthScorePresentation.explanation(for: reason))",
                comment: "Health Score tile a11y label with a withheld week-over-week delta"
            )
        } else {
            let delta = score.narratableDelta.map { $0 >= 0 ? "+\($0)" : "\($0)" } ?? "—"
            base = String(localized: "Health Score \(score.score) of 100, band \(bandLabel), change \(delta) from last week")
        }
        guard score.runsOnChosenComposition else { return base }
        return [base, HealthScorePresentation.chosenCompositionA11y].joined(separator: " ")
    }
}

/// Hero Health-Score delta — flat inline glyph + signed value, **no filled
/// pill**.
///
/// **v0.12 W3-8 (monochrome doctrine):** flattened from the filled
/// `deltaColor.opacity(0.18)` capsule to the same flat-inline-glyph treatment
/// the dashboard tiles use (`HLDashboardTile.TrendChip`). The hero was the
/// last surface mixing two trend vocabularies — a filled colored pill on the
/// score against the system's Withings-restraint flat mono arrows on every
/// tile below it. Colour is now signal-only: a *down* delta (score fell —
/// adverse, since higher is better) keeps `statusBad`; up / flat read
/// `HLText.secondary`. No `statusOK` green, matching the `TrendChip` rules.
private struct DeltaChip: View {
    let delta: Int

    var body: some View {
        HStack(spacing: HLSpace.xxs) {
            Image(systemName: arrow)
                .font(.hlIcon(HLIconSize.xs, weight: .bold))
            Text(deltaText)
                .font(.hlCaption.weight(.semibold))
                .monospacedDigit()
        }
        .foregroundStyle(deltaColor)
        .accessibilityLabel(accessibilityText)
    }

    private var arrow: String {
        if delta > 0 { return "arrow.up" }
        if delta < 0 { return "arrow.down" }
        return "minus"
    }

    private var deltaText: String {
        delta == 0 ? "0" : "\(abs(delta))"
    }

    /// Monochrome by default; `statusBad` only when the score fell (adverse
    /// for a higher-is-better metric). Mirrors `TrendChip.color` so the hero
    /// and the tiles speak one trend language.
    private var deltaColor: Color {
        delta < 0 ? HLColor.statusBad : HLText.secondary
    }

    private var accessibilityText: String {
        if delta > 0 {
            return String(localized: "Plus \(delta) from last week")
        }
        if delta < 0 {
            return String(localized: "Minus \(abs(delta)) from last week")
        }
        return String(localized: "Unchanged from last week")
    }
}

// MARK: - Loading / Error

struct HealthScoreSkeleton: View {
    var body: some View {
        // v0.12 W3-2 — the hero is the one surface that used to paint a flat
        // grey slab (`Circle().fill(HLColor.surface)` + static rects @ 0.6)
        // while every other card shimmered through `HLSkeleton`. Route the
        // ring + the caption/headline/subtitle silhouette through the shared
        // shimmer primitive so the hero loads like its children. `HLSkeleton`
        // owns the reduce-motion gate (static mid-value fill when on), so no
        // extra gating is needed here. Dimensions mirror `HealthScoreLoaded`:
        // 92pt ring, caption (14) · headline (18) · delta-subtitle (12).
        HStack(alignment: .center, spacing: HLSpace.lg) {
            HLSkeleton(.circle, width: 92, height: 92)
            VStack(alignment: .leading, spacing: HLSpace.xs) {
                HLSkeleton(.capsule, width: 100, height: 14)
                HLSkeleton(.capsule, width: 140, height: 18)
                HLSkeleton(.capsule, width: 80, height: 12)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement()
        .accessibilityLabel(Text("Health Score loading"))
    }
}

// MARK: - Observations strip (v0.5.4.2)

/// Compact chip strip rendered below the ring/headline row when the
/// caller passes briefing observations. Keeps the tile a single visual
/// block — the briefing-hero that used to sit above the tile is folded
/// into this row so the dashboard reads as one rhythm.
private struct HealthScoreObservationsStrip: View {
    let observations: [String]

    var body: some View {
        HStack(spacing: HLSpace.xs) {
            ForEach(Array(observations.prefix(3).enumerated()), id: \.offset) { _, text in
                Text(text)
                    .font(.hlCaption)
                    .foregroundStyle(HLText.secondary)
                    .padding(.vertical, HLSpace.xxs)
                    .padding(.horizontal, HLSpace.chip)
                    .background(
                        Capsule(style: .continuous)
                            .fill(HLColor.surfaceElevated)
                    )
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

struct HealthScoreErrorState: View {
    let error: HLError
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(HLColor.statusBad)
                Text("Health Score unavailable")
                    .font(.hlSubhead.weight(.semibold))
                    .foregroundStyle(HLText.primary)
            }
            Text(error.localizedDescription)
                .font(.hlCaption)
                .foregroundStyle(HLText.secondary)
            Button("Try again", action: retry)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }
}
