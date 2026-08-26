import SwiftUI

/// Design Tokens — Source of truth ist `design_handoff_healthlog_ios/tokens.css`.
/// Bei Änderung dort: hier nachziehen + Snapshot-Tests aktualisieren.
public enum HLColor {
    // MARK: - Brand (Dracula palette — locked against web `globals.css:109-134`)

    //
    // PA1 audit (2026-05-15) flagged `cyan` + `green` as systematically
    // de-saturated vs the canonical web Dracula palette. Re-pinned to the
    // exact hex values web ships, so iOS sparkline / sleep / pulse / steps
    // surfaces match `/dashboard` pixel-for-pixel. `yellow` filled the
    // handoff §1.4 BMI gap that had no iOS token at all.

    public static let cyan = Color(hex: 0x8BE9FD)
    public static let green = Color(hex: 0x50FA7B)
    public static let orange = Color(hex: 0xFFB86C)
    public static let red = Color(hex: 0xFF5555)
    public static let yellow = Color(hex: 0xF1FA8C)

    // MARK: - Ink (refined graphite for data-ink on light surfaces)

    /// Refined-graphite data-ink for chart lines + ring strokes on light
    /// surfaces. v0.14 light-mode walk: charts + rings previously resolved to
    /// `HLText.primary` — Apple-label parity, but dense data-ink read
    /// near-black/harsh on white. v0.14.11 light-theme redesign ("Warmes
    /// Papier"): the light slot is now a warm graphite `#454138` (≈9.6:1 on
    /// the `#FAF8F5` card) — clearly softer than the text ink so charts read
    /// "edel" rather than stark. **Text stays on `HLText.primary`** for
    /// label-parity contrast — only data-ink moves here. Dark mode keeps
    /// `#EBEBF5` (identical to `TextPrimaryMono` dark) so dark contrast is
    /// unchanged.
    public static let inkGraphite = Color("InkGraphite", bundle: .main)

    /// Solid dark scrim/pill fill that always carries WHITE foreground (undo
    /// toast capsule, dark capsules). Unlike `inkGraphite` (data-ink, inverts
    /// to near-white in dark), `inkScrim` stays dark in BOTH modes
    /// (`#26231F` light / `#2C2C2E` dark) so the white-on-dark pill never
    /// collapses. v0.14 replaced the pure-`Color.black` toast fill; v0.14.11
    /// warms the light slot to the paper-family near-black (white-on-scrim
    /// still ≈15.6:1) so the pill sits in the warm palette instead of
    /// punching a cold black hole into the light canvas.
    public static let inkScrim = Color("InkScrim", bundle: .main)

    // MARK: - AI-hero brand moment (the ONE sanctioned chroma-free white/black)

    //
    // FW1-C (M6): the Coach "Ask the Coach" hero card + collapsed coin paint a
    // deliberate AI-brand moment — pure WHITE foreground on a near-BLACK
    // ink-gradient scrim, in BOTH appearances (the gradient does not invert; an
    // AI moment that flips to black-on-white in light mode loses the "premium
    // intelligence" read). This is the second sanctioned monochrome exception
    // after `skipBeam`. Previously these were raw `Color.white` / `Color.black`
    // literals scattered across `Screens/Coach/**`, firing `forbidden_color`
    // and leaving the exception un-auditable. Routing them through these tokens
    // keeps DesignSystem the single home for raw colours and makes the
    // exception greppable. They are intentionally appearance-INVARIANT (unlike
    // `inkScrim`, which is an asset-catalog colour) — the AI hero must read
    // identically in light + dark.

    /// White foreground/ink for the AI-hero brand moment (Coach hero + coin).
    /// Appearance-invariant by design.
    public static let aiHeroInk = Color.white

    /// Near-black scrim base for the AI-hero ink gradient. Appearance-invariant
    /// by design (the AI moment does not invert in light mode).
    public static let aiHeroScrim = Color.black

    /// v0.14.3 B1 — the sanctioned COLOURFUL Coach-hero gradient. The operator
    /// brief explicitly wants the Coach tile to read as a real, vivid "hero"
    /// (purple → amber), the ONE chromatic exception to the monochrome doctrine
    /// (alongside `aiHeroInk`/`aiHeroScrim`). Appearance-invariant — the AI
    /// moment must read identically in light + dark. White (`aiHeroInk`) chrome
    /// stays legible across the whole sweep (deep indigo→violet→warm amber).
    public static let aiHeroGradient = Gradient(colors: [
        Color(hex: 0x4C1D95), // deep violet (indigo-900-ish)
        Color(hex: 0x7C3AED), // vivid purple
        Color(hex: 0xF59E0B) // warm amber
    ])

    // MARK: - PersonalRecords hero moment (sanctioned monochrome white/black)

    //
    // v0.14.8 W2 (Audit §1.1) — the PersonalRecords hero card, share image and
    // celebration overlay paint white-on-dark gradient moments in the
    // Apple-Fitness-Award visual language. Like the AI-hero moment above they
    // are appearance-INVARIANT by design: the kind-tint→near-black gradient and
    // its white spotlight/watermark/chrome must NOT invert in light mode (a
    // record hero that flips to black-on-white loses the award read), and the
    // 1080×1080 share PNG must render identically regardless of the device
    // appearance at export time. Previously raw `Color.white`/`Color.black`
    // literals scattered across `Screens/PersonalRecords/**` — the last
    // chroma-drift folder outside DesignSystem. Routed through these tokens so
    // DesignSystem stays the single auditable home for raw colours.

    /// White ink/highlight for the record-hero gradients (corner spotlight,
    /// trophy watermark, slot capsule). Appearance-invariant by design.
    public static let recordHeroInk = Color.white

    /// Near-black scrim base for the record-hero gradients + glass fallbacks
    /// (hero gradient floor, share-image floor, share-button fallback).
    /// Appearance-invariant by design.
    public static let recordHeroScrim = Color.black

    // MARK: - Wellness-score convergent gradients (v0.14.4 FW-WELL)

    //
    // v0.14.4 FW-WELL — the FOUR top wellness-score cards ("Deine
    // Gesundheitswerte": Tagesform / Schlaf-Score / Tagesbelastung /
    // Cardio-Fitness) each carry a per-card diagonal `LinearGradient` Verlauf.
    // This is a SANCTIONED chromatic exception to the monochrome doctrine
    // (alongside the Coach hero, `aiHeroGradient`), explicitly requested by the
    // operator. Like the Coach hero these literals live ONLY here so the
    // exception is auditable in one place and stays `forbidden_color`-clean
    // (DesignSystem/ is excluded from that rule); none use `Color.purple` etc.,
    // so the `forbidden_purple` ERROR rule (identifier-match) is also satisfied.
    //
    // **The convergence contract.** The cards sit in a 2×2 grid. The LIGHT end
    // of every gradient is the card's INNER corner (nearest the grid centre) and
    // is the SAME shared warm near-white token (`wellnessGradientLight`) on all
    // four — so "die hellen Werte laufen zueinander" (all four light corners
    // meet at the grid centre). The saturated metric hue sits at the OUTER
    // corner. The corner→start/end mapping is `WellnessGradient.LightCorner`.

    /// The shared warm near-white LIGHT end of every wellness-score gradient.
    /// IDENTICAL across all four cards so their light corners converge at the
    /// grid centre into one continuous warm field. Appearance-invariant (the
    /// gradients read identically light + dark, like the Coach hero).
    public static let wellnessGradientLight = Color(hex: 0xFBF5EC) // warm beige near-white

    /// **v0.14.10 §1 — the DARK convergent base of every wellness-score gradient.**
    ///
    /// The operator flagged the prior light-blended tiles as "zu hell, sehr weiß
    /// und bold" / washed out. The gradient direction is now REVERSED: each
    /// saturated metric hue is blended toward this near-black graphite card base
    /// (a touch above the app `Surface` `#2E3140` / `Background` `#16171C` so the
    /// tile still reads as a card, not a hole) and the inner grid-centre corner
    /// converges to this same dark base. Tiles read tinted-DARK + calm +
    /// monochrome-coherent, and the WHITE ring + value + label stay crisp on the
    /// dark field. Appearance-invariant so the tiles read identically light + dark.
    public static let wellnessGradientDark = Color(hex: 0x23262F) // tinted near-black card base

    /// v0.14.10 §1 — a faint WHITE radial lift under the ring/label lockup on the
    /// now-DARK wellness tiles. Adds a subtle premium glow without lightening the
    /// tile. Hoisted here (DesignSystem) so the screen code stays raw-colour-free.
    public static let wellnessTileGlow = Color.white.opacity(0.06)

    /// v0.14.10 §1 — the subtle hairline border on the dark wellness tiles (was a
    /// warm-beige edge tuned for the old light tiles; now a faint white edge that
    /// reads as a card rim on the near-black field).
    public static let wellnessTileBorder = Color.white.opacity(0.10)

    /// The saturated OUTER-corner hue for each wellness score. Distinct per
    /// metric; the two greens (Tagesform vs. Cardio-Fitness) are deliberately
    /// pulled apart (leaf-green vs. teal-green) so the cards are not identical.
    public static let wellnessTagesformHue = Color(hex: 0x2FA85A) // leaf green
    public static let wellnessSchlafHue = Color(hex: 0x1E3A8A) // dark blue (→ light → beige via shared light end)
    public static let wellnessBelastungHue = Color(hex: 0x6D4AC4) // purple (NOT red)
    public static let wellnessCardioHue = Color(hex: 0x0E8C82) // teal-green (distinct from Tagesform)
    /// v0.14.9 §3 — Erholung/Recovery: warm honey-yellow into beige. The
    /// terracotta (`#E07A5F`) read as reddish ("Erholung hat nichts mit Rot zu
    /// tun"); honey-yellow reads calm + restorative, stays in the warm
    /// convergent-gradient family, and is clearly apart from Schlaf-blue +
    /// Tagesform-green.
    public static let wellnessRecoveryHue = Color(hex: 0xE0A94F) // warm honey-yellow
    /// v0.14.8 Item-2 — Belastungs-Stress: muted clay-rose, same warm family as
    /// Recovery but pulled apart so the two tiles aren't identical.
    public static let wellnessStressHue = Color(hex: 0xC65B5B) // muted clay-rose
    /// v0.14.9 §2 — Vascular age (re-frame promoted to a years-delta ring tile):
    /// soft violet, distinct from Belastung-purple but the same cool family.
    public static let wellnessVascularHue = Color(hex: 0x9A6BC4) // soft violet
    /// v0.14.9 §2 — HRV balance (band re-frame promoted to a ring tile): calm
    /// steel-blue, clearly cooler/greyer than the Schlaf navy so the two read apart.
    public static let wellnessHrvBalanceHue = Color(hex: 0x4A8FB0) // calm steel-blue

    /// **v0.14.8 Item-1 — contrast-safe wellness-RING fill on the beige card.**
    ///
    /// The wellness ring fill MUST NOT use `HLChartTints.series` (→ `inkGraphite`,
    /// which flips to near-white `#EBEBF5` in dark mode). The wellness gradient
    /// card's light end + radial scrim are appearance-INVARIANT warm beige
    /// (`#FBF5EC`), so a near-white fill vanishes on it in dark mode. This is a
    /// scheme-STABLE graphite (`#2C2C2E`, never inverts) — legible on the beige
    /// gradient + scrim in BOTH light and dark. The unfilled track stays the
    /// subtle `HLText.primary @ lineOpacity` channel.
    public static let wellnessRingInk = Color(hex: 0x2C2C2E) // scheme-stable graphite

    // MARK: - Surfaces (Asset-Catalog, system-aware Light/Dark)

    public static let background = Color("Background", bundle: .main)
    public static let backgroundEleva = Color("BackgroundElevated", bundle: .main)
    public static let surface = Color("Surface", bundle: .main)
    public static let surfaceElevated = Color("SurfaceElevated", bundle: .main)
    public static let separator = Color("Separator", bundle: .main)

    // MARK: - Canonical Dracula background (operator-flippable, default OFF)

    //
    // C-8 marathon decision (2026-05-16, R1 Strategy C migration):
    // The asset-catalog `Background` dark is `#16171C` — a cooler, darker
    // graphite picked in v0.4.0 §A6 as a deliberate iOS-handschrift retune.
    // The canonical web Dracula background is `#282A36` (`globals.css:109`),
    // which PA1 §6.1 flagged as the largest single perceptual gap between
    // web and iOS.
    //
    // R1 Strategy C calls for `#1E2128` as the eventual target, but the
    // decision is deferred until operator has felt the Theme C-1..C-7
    // chrome-monochrome work on real hardware. To keep the option open
    // without flipping the visual today, we expose the canonical hex as a
    // first-class token here and gate consumption behind a single boolean.
    //
    // **Default behaviour is unchanged** — every surface still resolves to
    // the asset-catalog `Background` (`#16171C` dark). When the operator
    // says "switch to canonical Dracula background", flip
    // `useCanonicalDraculaBackground` to `true` below — that's the
    // entire change. Consumers should prefer `HLColor.canvasBackground`
    // (computed below) over `HLColor.background` in new code so the flip
    // cascades automatically when it happens.

    /// Canonical Dracula background hex from `globals.css:109` (web parity).
    /// Exposed as a code-level token so a future flip is purely token-layer.
    public static let surfaceCanonicalDracula = Color(hex: 0x282A36)

    /// Operator-flippable switch — `false` keeps the v0.4.0 §A6 retune
    /// (`Background` asset → `#16171C` dark, `#F5F5F8` light). Setting to
    /// `true` routes `canvasBackground` to `surfaceCanonicalDracula`
    /// (`#282A36`) on every surface that consumes the alias. Default-off
    /// pending the R1 Strategy C felt-walkthrough.
    public static let useCanonicalDraculaBackground = false

    /// Resolved canvas background — single chokepoint for the C-8 flip.
    /// Prefer this in new code. When `useCanonicalDraculaBackground` is
    /// `true` (one-line flip above), every consumer receives the canonical
    /// Dracula `#282A36`; otherwise the asset-catalog `Background` ships
    /// (system-aware light/dark, currently `#F2F0EB / #16171C`).
    public static var canvasBackground: Color {
        useCanonicalDraculaBackground ? surfaceCanonicalDracula : background
    }

    // MARK: - Text

    public static let textPrimary = Color("TextPrimary", bundle: .main)
    public static let textSecondary = Color("TextSecondary", bundle: .main)
    public static let textTertiary = Color("TextTertiary", bundle: .main)

    // MARK: - Status (Traffic-Light) — dual-appearance light/dark colorsets

    //
    // Web maps `--success → dracula-green`, `--warning → dracula-orange`,
    // `--destructive → dracula-red` in dark mode (`globals.css:185-187`).
    // The DARK slot of each colorset keeps those exact Dracula hues
    // (`#50FA7B` / `#FFB86C` / `#FF5555`). The Any/LIGHT slot is retuned to
    // calmer, legible-on-white values (W-LIGHT v0.8.0; deepened again in the
    // v0.14.11 "Warmes Papier" light redesign) — hues that pop on charcoal
    // are too bright/saturated on paper, and the prior light green/amber
    // (`#1F8A4C` @ 4.1:1 / `#C8761E` @ 3.3:1) failed WCAG AA text on the
    // warm card. The new light slots are deep, low-chroma signal tones that
    // clear 4.5:1 on card AND canvas while keeping their semantics. Promoting
    // to colorsets (mirrors `HLText` / `HLSurface`) leaves all ~186
    // call-sites routing through these tokens unchanged.
    //
    // Light: green `#2B774B` (5.2:1) / amber `#9B5D10` (5.0:1) /
    //        red `#B23E3B` (5.4:1) — ratios vs card `#FAF8F5`.
    // Dark:  green `#50FA7B` / amber `#FFB86C` / red `#FF5555` (Dracula).

    public static let statusOK = Color("StatusOK", bundle: .main)
    public static let statusWarn = Color("StatusWarn", bundle: .main)
    public static let statusBad = Color("StatusBad", bundle: .main)

    /// **v0.14.1 ITEM-B — sanctioned skip-signal dark-orange.**
    ///
    /// The intake-confirm border-beam (`HLBorderBeam`) is monochrome silver
    /// for "Genommen". The "Überspringen" sweep is the SAME beam but tinted a
    /// deliberate dark orange (`dunkelorange`) so a skip reads as a distinct,
    /// non-neutral signal at a glance. This is the ONE sanctioned chromatic
    /// exception to the monochrome doctrine — confined to the skip-beam
    /// overlay (decorative chrome, never data-ink, never a CTA). Defined as a
    /// fixed sRGB literal (not a system `Color.orange`, which the
    /// `forbidden_color` rule blocks outside DesignSystem) so the hue is
    /// pinned `#B5651D` and identical in light + dark.
    public static let skipBeam = Color(red: 0.71, green: 0.40, blue: 0.11)

    // MARK: - Sleep-stage palette (W-SLEEPHYP, sanctioned category colors)

    //
    // The hypnogram's stages are FOUR fixed, mutually-exclusive CATEGORIES
    // (Wach / REM / Kern / Tief, plus the coarse Im-Bett container + the
    // stage-unknown ASLEEP bucket) — not a continuous data-ink ramp. The
    // monochrome doctrine ("opacity is the only signal") leaves the phases
    // visually indistinguishable, which was the operator finding. Category
    // colors are the sanctioned exception here: a muted PASTEL spectrum tone
    // per phase, never neon, each defined as an adaptive asset-catalog color
    // so light + dark both stay legible on the card surface. The hues carry
    // MEANING only as a phase legend, paired with a text legend + a11y labels.
    public static let sleepStageAwake = Color("SleepStageAwake", bundle: .main)
    public static let sleepStageREM = Color("SleepStageREM", bundle: .main)
    public static let sleepStageCore = Color("SleepStageCore", bundle: .main)
    public static let sleepStageDeep = Color("SleepStageDeep", bundle: .main)
    public static let sleepStageInBed = Color("SleepStageInBed", bundle: .main)
    public static let sleepStageAsleep = Color("SleepStageAsleep", bundle: .main)

    // MARK: - Theme-2.0 deletion log (T2-5 final, 2026-05-16)

    //
    // The legacy per-metric namespace (`metricWeight / .metricBP / .metricPulse
    // / .metricGlucose / .metricSleep / .metricSteps / .metricMood / .metricMeds`
    // — ×8) and the dashboard-category namespace (`dashboardCategoryVitals /
    // .Activity / .Body / .Sleep / .Other` — ×5) lived here through T2-1's
    // hybrid cutover so T2-2 / T2-3 / T2-4 could sweep their consumers at
    // leisure. T2-5 finalises the rework: every production call-site now routes
    // through `HLChartTints.series` (chart data), `HLAccent.primary`
    // (CTA / active / selected), or `HLSurface.secondary` (passive card), and
    // the legacy aliases have been removed.
    //
    // Lock-tests anchoring the contract live in:
    //   - `TokensRegressionTests.categoryTintsCollapseToMonoSurface` — locks
    //     `HLSurface.secondary` to operator-locked white / lifted-charcoal hex.
    //   - `TokensRegressionTests.chartSeriesTintsCollapseToSingleAccent` —
    //     locks `HLChartTints.series` + `HLAccent.primary` to the monochrome
    //     `HLText.primary` (v0.8.1 monochrome-restore — was Dracula-Purple).
    //   - `MetricKindDescriptorRegistryTests.descriptorTintsCollapseToMonoSurface`
    //     — locks every descriptor's `tint` field to the mono card surface.
}

/// **v0.14.4 FW-WELL — pure descriptor for the convergent wellness gradients.**
///
/// Maps each of the four wellness-score cards to its saturated OUTER-corner hue
/// and the INNER corner that holds the shared light end (`HLColor
/// .wellnessGradientLight`). Hoisted out of the view + made `nonisolated` /
/// `Sendable` so the score→(hue, light-corner) contract is unit-testable
/// without a SwiftUI host. The view layer turns a `case` into a `LinearGradient`
/// via `linearGradient` (saturated hue at the outer corner → light at the inner
/// corner), giving the 2×2 convergence ("die hellen Werte laufen zueinander").
public enum WellnessGradient: Sendable, CaseIterable {
    case tagesform // top-left  → light corner bottom-trailing
    case schlaf // top-right → light corner bottom-leading
    case belastung // bottom-left → light corner top-trailing
    case cardio // bottom-right → light corner top-leading
    case recovery // v0.14.9 §3 — Erholung, warm honey-yellow → beige
    case stress // v0.14.8 Item-2 — Stress, muted clay-rose → beige
    case vascular // v0.14.9 §2 — Vascular age (years-delta ring), soft violet → beige
    case hrvBalance // v0.14.9 §2 — HRV balance (band ring), calm steel-blue → beige

    /// Which corner of the card holds the SHARED light end (the grid-centre
    /// corner). The saturated hue lives at the diagonally OPPOSITE outer corner.
    public enum LightCorner: Sendable {
        case topLeading, topTrailing, bottomLeading, bottomTrailing

        /// SwiftUI start/end for a `LinearGradient` whose FIRST stop (saturated
        /// hue) sits at the OUTER corner and whose LAST stop (light) sits at
        /// THIS (inner) corner.
        var gradientPoints: (start: UnitPoint, end: UnitPoint) {
            switch self {
            case .bottomTrailing: (.topLeading, .bottomTrailing) // hue TL → light BR
            case .bottomLeading: (.topTrailing, .bottomLeading) // hue TR → light BL
            case .topTrailing: (.bottomLeading, .topTrailing) // hue BL → light TR
            case .topLeading: (.bottomTrailing, .topLeading) // hue BR → light TL
            }
        }
    }

    /// The card's INNER corner (nearest the grid centre) per the operator's
    /// 2×2 layout — all four converge at the centre.
    public var lightCorner: LightCorner {
        switch self {
        case .tagesform: .bottomTrailing
        case .schlaf: .bottomLeading
        case .belastung: .topTrailing
        case .cardio: .topLeading
        // v0.14.8 Item-2 — the promoted warm scores sit in the lower grid rows;
        // mirror the top pair (light toward the grid centre) so the warm corners
        // still converge into the shared beige field.
        case .recovery: .bottomTrailing
        case .stress: .bottomLeading
        // v0.14.9 §2 — the two newly-promoted re-frames sit in the lower grid
        // rows; mirror the inner-corner convergence so all light corners still
        // meet at the grid centre.
        case .vascular: .topTrailing
        case .hrvBalance: .topLeading
        }
    }

    /// The saturated OUTER-corner hue for this score (distinct per metric; the
    /// two greens are deliberately pulled apart).
    public var hue: Color {
        switch self {
        case .tagesform: HLColor.wellnessTagesformHue
        case .schlaf: HLColor.wellnessSchlafHue
        case .belastung: HLColor.wellnessBelastungHue
        case .cardio: HLColor.wellnessCardioHue
        case .recovery: HLColor.wellnessRecoveryHue
        case .stress: HLColor.wellnessStressHue
        case .vascular: HLColor.wellnessVascularHue
        case .hrvBalance: HLColor.wellnessHrvBalanceHue
        }
    }

    /// Maps a wellness derived-metric ID (`READINESS` / `SLEEP_SCORE` /
    /// `STRAIN_SCORE` / `FITNESS_AGE`) to its gradient case. `nil` for any other
    /// ID (the card then keeps the plain mono surface).
    public nonisolated static func forMetricID(_ id: String) -> WellnessGradient? {
        switch id {
        case "READINESS": .tagesform
        case "SLEEP_SCORE": .schlaf
        case "STRAIN_SCORE": .belastung
        case "FITNESS_AGE": .cardio
        case "RECOVERY_SCORE": .recovery
        case "STRESS_SCORE": .stress
        case "VASCULAR_AGE_DELTA": .vascular
        case "HRV_BALANCE": .hrvBalance
        default: nil
        }
    }

    /// **v0.14.10 §1 — gradient direction REVERSED toward the dark base.**
    ///
    /// The prior pass blended each hue ~45% toward the warm LIGHT end, which the
    /// operator flagged as "zu hell, sehr weiß und bold" / washed out. The blend
    /// now runs toward the near-black `wellnessGradientDark` card base instead:
    /// each saturated `hue` is pulled `darkenTowardBase` of the way toward that
    /// dark grey, so the outer corner is a TINTED-DARK colour (a subtle, still-
    /// identifiable hue), not a pale one. The white ring + value + label stay
    /// crisp because the whole tile is now dark. The mid stop + the radial scrim
    /// + the ring's own dark-shadow safeguard all still hold.
    nonisolated static let darkenTowardBase: Double = 0.72

    /// The saturated hue, blended `darkenTowardBase` toward the near-black card
    /// base — the calm, tinted-dark outer-corner colour the gradient starts from.
    /// Retains ~28% of the metric hue so each tile stays identifiable but muted.
    public var darkenedHue: Color {
        hue.blended(with: HLColor.wellnessGradientDark, fraction: Self.darkenTowardBase)
    }

    /// The convergent `LinearGradient`: the TINTED-DARK `hue` at the outer corner,
    /// blending through a mid stop to the shared near-black `wellnessGradientDark`
    /// at the inner grid-centre corner. v0.14.10 §1 — direction flipped from the
    /// old hue→light sweep to hue→dark so the tiles sit in the app's near-black
    /// monochrome tone with only a subtle warm hue; white ring stays legible.
    public var linearGradient: LinearGradient {
        let points = lightCorner.gradientPoints
        let tinted = darkenedHue
        return LinearGradient(
            stops: [
                .init(color: tinted, location: 0),
                .init(
                    color: tinted.blended(with: HLColor.wellnessGradientDark, fraction: 0.5),
                    location: 0.5
                ),
                .init(color: HLColor.wellnessGradientDark, location: 1)
            ],
            startPoint: points.start,
            endPoint: points.end
        )
    }
}

public extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }

    /// Linearly blends this colour toward `other` by `fraction` (0 = self, 1 =
    /// `other`) in sRGB. Used by the wellness gradients to pre-soften the
    /// saturated hue toward the shared warm light end (v0.14.9 §4 intensity cut).
    /// `nonisolated` + resolved via `Color.Resolved` so it works off the main
    /// actor in the pure gradient descriptor + its unit tests.
    nonisolated func blended(with other: Color, fraction: Double) -> Color {
        let t = max(0, min(1, fraction))
        let a = resolve(in: EnvironmentValues())
        let b = other.resolve(in: EnvironmentValues())
        return Color(
            .sRGB,
            red: Double(a.red) + (Double(b.red) - Double(a.red)) * t,
            green: Double(a.green) + (Double(b.green) - Double(a.green)) * t,
            blue: Double(a.blue) + (Double(b.blue) - Double(a.blue)) * t,
            opacity: Double(a.opacity) + (Double(b.opacity) - Double(a.opacity)) * t
        )
    }
}

// MARK: - Icon-glyph size tokens (SF-Symbol point sizes)

/// Canonical point-size scale for **SF-Symbol glyphs** — the single source
/// for `.font(.system(size:))` on `Image(systemName:)` so glyph sizes stop
/// drifting (13 vs 14 vs 16 across sibling Settings rows; 5/6/9 status dots;
/// 22/24/28/56 hero glyphs). Mirrors the `HLSpace`/`HLRadius` style.
///
/// **Why a fixed pixel size is correct for glyphs (not text):** symbol glyphs
/// are decorative geometry that must keep their proportions relative to the
/// surrounding fixed-size chrome (icon chips, status rows, hero medallions).
/// Unlike *text*, they are not the thing a low-vision user reads, so locking
/// them is the doctrine-sanctioned exception — but the size must come from
/// this scale, not a raw literal. Apply via `.font(HLIconSize.rowAction.font)`.
///
/// `Tokens.swift` is excluded from the `dynamic_type_bypass` lint rule, so the
/// raw `.system(size:)` lives here once and call-sites stay clean.
public enum HLIconSize {
    /// 11pt — micro glyph (legend dots, inline meta carets).
    public static let xs: CGFloat = 11
    /// 13pt — small glyph (settings icon-chip interior, dense inline icons).
    public static let sm: CGFloat = 13
    /// 15pt — standard glyph (settings action-row leading icon, list-row icons).
    public static let md: CGFloat = 15
    /// 20pt — large glyph (toolbar / prominent inline affordances).
    public static let lg: CGFloat = 20
    /// 28pt — hero glyph (empty-state medallions, card-hero symbols).
    public static let hero: CGFloat = 28
    /// 36pt — display glyph (onboarding-step heroes, detail-screen medallions).
    /// Audit-01 H2: collapses the former 32/36pt ad-hoc cluster.
    public static let display: CGFloat = 36
    /// 56pt — cover glyph (privacy cover, lock overlay, loading screen,
    /// full-screen import heroes). Audit-01 H2: collapses the former
    /// 48/56/80pt ad-hoc cluster — the LARGEST sanctioned glyph size.
    public static let cover: CGFloat = 56

    // MARK: - Semantic aliases (prefer at call-sites)

    /// Leading glyph inside a settings / list action row (= `.md`, 15pt).
    public static let rowAction: CGFloat = md
    /// Glyph inside the 26×26 `HLSettingsIconChip` (= `.sm`, 13pt).
    public static let chip: CGFloat = sm
    /// Status-dot / inline-state glyph (= `.xs`, 11pt).
    public static let statusDot: CGFloat = xs
}

public extension Font {
    /// Convenience: a fixed-size SF-Symbol font from an `HLIconSize` point value.
    /// Use for `Image(systemName:).font(.hlIcon(HLIconSize.rowAction))`.
    static func hlIcon(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        // Intentional fixed size: SF-Symbol glyph sizing routed through the
        // canonical `HLIconSize` scale (see the enum's doc-comment for why
        // glyphs are pixel-locked while text is not). `Tokens.swift` is the
        // single sanctioned home for the raw `.system(size:)` glyph call.
        .system(size: size, weight: weight)
    }
}

public extension Font {
    // MARK: - Text-Tokens (Dynamic-Type-aware via Apple's semantic styles)

    //
    // Default-Pixel-Größen at "Large" Dynamic-Type-setting matchen 1:1 unsere
    // bisherigen `Font.system(size:)` Werte. Skaliert automatisch zwischen XS
    // (~80%) und Accessibility XXXL (~250%). Audit-Befund M5 (TestFlight a11y
    // review blocker) damit erledigt.

    static let hlLargeTitle = Font.system(.largeTitle, weight: .bold) // 34pt @ Large
    static let hlTitle1 = Font.system(.title, weight: .bold) // 28pt @ Large
    static let hlTitle2 = Font.system(.title2, weight: .bold) // 22pt @ Large
    static let hlTitle3 = Font.system(.title3, weight: .semibold) // 20pt @ Large
    static let hlHeadline = Font.system(.headline) // 17pt semibold
    static let hlBody = Font.system(.body) // 17pt
    static let hlCallout = Font.system(.callout) // 16pt
    static let hlSubhead = Font.system(.subheadline) // 15pt
    static let hlFootnote = Font.system(.footnote) // 13pt
    static let hlCaption = Font.system(.caption) // 12pt
    static let hlCaption2 = Font.system(.caption2) // 11pt — legend / micro-labels

    // MARK: - Metric-Values (numerische Anzeigen, SF Pro Rounded Bold)

    /// Dynamic-Type-aware Metric-Variante. **Empfohlen für neuen Code.**
    /// Skaliert mit Apple-Semantic-Style; Caller wählt den Style.
    static func hlMetric(_ style: Font.TextStyle) -> Font {
        .system(style, design: .rounded, weight: .bold)
    }

    /// Pixel-exakte Variante — skaliert NICHT mit Dynamic Type.
    /// Nur nutzen wenn absolute Größen-Kontrolle nötig (z.B. über `frame`
    /// positionierte Overlays). Sonst die TextStyle-Variante oder `@ScaledMetric`
    /// im Caller verwenden.
    static func hlMetric(_ size: CGFloat) -> Font {
        // Intentional fixed size:
        // This is the explicit fixed-size escape hatch — callers opt-in by
        // picking this overload when they need pixel-locked numerics.
        // swiftlint:disable:next dynamic_type_bypass
        .system(size: size, weight: .bold, design: .rounded)
    }
}
