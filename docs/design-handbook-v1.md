# HealthLog iOS — Design Handbook v1

**Status:** Locked specification, v0.6.1 onwards.
**Owner:** HealthLog maintainer.
**Origin:** Y0 research (2026-05-23) — derived from operator verdict "Startseite gefällt mir sehr gut. Akzentfarbe Weiß, Layout Karten, Erscheinungsbild Dunkel. Das ist mein Standard." plus full code-audit of every screen in `HealthLog/Screens/`.
**Companion:** Section-6 drift matrix is the implementation backlog for Y1–Y7. Section-7 maps findings to waves.

Apple Design Award quality is the bar. Every section is actionable. No theory.

---

## 1. Foundation

### 1.1 Themes

**Light + Dark only.** The accent-picker (`HLTint` enum, eight choices) is **deprecated** as of v0.6.1.

Migration rules:
- The enum stays for source-compat through one release; consumers (`HLChartTints`, `HLButton`, `HLAccent.userBrandTint`, `Toggle/Picker .tint(...)`) all collapse to `HLText.primary` as the canonical accent.
- `UserDefaults` key `hl.settings.tint` is read once at boot, value is logged + ignored. No new writes. v0.6.2 removes the picker UI + the enum.
- Light/Dark follows system; we never paint over `colorScheme`.
- Forbidden: any per-user accent persistence, picker UI, `userBrandTint` reads in new code.

### 1.2 Color palette

**Doctrine:** monochrome surfaces + monochrome text + monochrome chrome. Color appears only as a **signal** for status, severity, or "in target" callouts. The brand anchor (Dracula-Purple `#BD93F9`) stays alive on **brand-anchor surfaces only** (LaunchScreen splash, AccentColor asset, Onboarding hero) — every in-app surface goes mono.

#### Canonical surface tokens (use these in all new code)

| Token | Light | Dark | Usage |
|---|---|---|---|
| `HLSurface.primary` | `#F7F7F8` | `#101113` | Full-screen canvas. Every `hlScreenBackground()` resolves here. |
| `HLSurface.secondary` | `#FFFFFF` | `#1A1B1F` | Card / tile backing (`HLCard` default). |
| `HLSurface.tertiary` | `#EDEDF0` | `#25262B` | Recessed wells (chip backgrounds, inset rows, disabled). |

#### Canonical text tokens

| Token | Light | Dark | Usage |
|---|---|---|---|
| `HLText.primary` | `#1C1C1E` | `#EBEBF5` | Headings, body, primary metric values. **This is the new accent for chrome.** |
| `HLText.secondary` | primary @70% | primary @70% | Captions, meta, units, secondary metric icons. |
| `HLText.tertiary` | primary @40% | primary @40% | Disabled, placeholder, decorative chrome, monochrome sparkline. |

#### Signal palette (the only colors permitted in production v2)

| Token | Hex | Purpose | Where it can appear |
|---|---|---|---|
| `HLColor.statusOK` | `#50FA7B` | Success / "im Zielbereich" / Genommen / favorable threshold | Compliance checkmark, BP in-target badge, ring band-green |
| `HLColor.statusWarn` | `#FFB86C` | Warning / mild deviation / out-of-window | Low-stock pen, BP mild-hypertension chip |
| `HLColor.statusBad` | `#FF5555` | Error / overdue / adverse trend / destructive | Überfällig banner, adverse `TrendChip`, delete buttons, sign-out |

The status hexes are unchanged from Dracula — they remain semantically locked.

#### Banned in v2 (drift-list — search-and-destroy in Y1)

These hex anchors and shapes **must not appear on any in-app surface** after Y1 lands:

| Banned color | What it was | Replace with |
|---|---|---|
| `HLColor.purpleDeep` (`#7C5CD8`) on chart marks | PK chart line + dot | `HLText.primary` |
| `HLColor.purple` (`#BD93F9`) used as chrome / icon foreground / row hero | Coach hero, Onboarding ladders, `MedicationDetailScreen` hero circle | `HLText.primary` for chrome, `.tint` inherited (which we re-route to `HLText.primary`) |
| `HLColor.cyan` direct usage | `InjectionSitePicker.suggested`, `TitrationLadderSection.nextStepHint`, ChartDetail `SourcesRow` (Withings source) | `HLText.secondary` |
| `HLColor.pink` direct gradient pair on Coach hero / coin | `AskCoachHeroCard`, `AskCoachCollapsedCoin` | Mono surface (no gradient) — see §2.x Coach Hero redesign |
| `HLColor.orange` direct usage on `import_` source pill | `ChartDetailScreen.SourcesRow` | `HLText.secondary` |
| Any **dark-blue / Indigo / `Color.blue`** appearing on time-range pills or Min/Max/Median pills | iOS-system-blue artifact when accent picker = `.systemBlue` | `HLText.primary` (text-only pills, transparent fill) |
| Coach-hero gradient `[purple → pink]` | `AskCoachHeroCard.content` | Solid mono `HLSurface.secondary` card with chrome icon — see §2.x |

### 1.3 Typography

Dynamic-Type-aware via Apple's semantic styles. Pixel sizes below are at "Large" setting.

| Token | Style | Pixel @ L | Usage |
|---|---|---|---|
| `Font.hlLargeTitle` | `.largeTitle .bold` | 34pt | Screen title in DashboardHeader/MoreHeader (operator wants this only for those two header rows + EditProfile heroes). |
| `Font.hlTitle1` | `.title .bold` | 28pt | Reserved — used on Onboarding splashes only. |
| `Font.hlTitle2` | `.title2 .bold` | 22pt | Card headline (HealthScoreLoaded headline, MedicationHero name, hero email). |
| `Font.hlTitle3` | `.title3 .semibold` | 20pt | Section title inside a card (HighlightInsightCard title, Per-Kind insight value). |
| `Font.hlHeadline` | `.headline` | 17pt | Row title in dense list rows (LastDose name, InventorySection pen count). |
| `Font.hlBody` | `.body` | 17pt | Body copy inside cards. |
| `Font.hlCallout` | `.callout` | 16pt | Reserved — rarely used; prefer Subhead. |
| `Font.hlSubhead` | `.subheadline` | 15pt | Row title for list-rows in the Home/Dashboard rhythm (CapturePickerRow title, Active-medication row name, hero subtitle, MetricSource pill). |
| `Font.hlFootnote` | `.footnote` | 13pt | Uppercase section labels (`Apple-Health "HEUTE / VERLAUF / PLAN"` rhythm). Tracking 0.5, `.textCase(.uppercase)`. |
| `Font.hlCaption` | `.caption` | 12pt | Meta/units/captions; chips; under-line descriptors. |
| `Font.hlMetric(_:)` | rounded `.bold` | scales | Numeric displays (tile primary value, hero stat values). |

**Hierarchy rule (locks operator's "Hierarchy broken" complaints):**
- A row's **title** is always equal-or-larger than its **subtitle**.
- A card's **headline** is always equal-or-larger than its **body** copy.
- A button's label font is always equal-or-larger than the supporting caption beneath it.
- `.hlBody` (17pt) is **never** smaller than the title above it. The Settings Integrations "Lese-/Schreibzugriff relativ" footer needs to upgrade out of `.hlCaption` → `.hlSubhead` to clear this rule.

### 1.4 Spacing rhythm

`HLSpace` (4pt grid + named subgrid). **No raw `CGFloat` padding in views.**

| Token | pt | Canonical use |
|---|---|---|
| `hair` | 1 | Hairline-clip avoidance |
| `xxs` | 2 | Optical tuning in dense rows |
| `xs` | 4 | Icon-to-text in buttons + chips |
| `chip` | 6 | Chip-vertical internal padding |
| `sm` | 8 | Row-vertical, badge inset, ring stroke |
| `md` | 12 | Card-internal stacks, Form-field gap |
| `lg` | 16 | **Edge-Inset standard.** Card-padding standard. Screen `.padding(.horizontal, HLSpace.lg)` is mandatory. |
| `xl` | 20 | Section-top-gap (legacy onboarding) |
| `xxl` | 24 | Section-gap |
| `xxxl` | 32 | Hero-section-gap |
| `xxxxl` | 40 | Maximum (empty-state hero) |

**Canonical screen padding rhythm:**
- `.padding(.horizontal, HLSpace.lg)` — screen edges, all `ScrollView`s.
- `.padding(.top, HLSpace.lg)` — distance from nav-bar to first content row.
- `.padding(.bottom, HLSpace.lg)` — distance to bottom safe-area (tab-bar inset is automatic on iOS 18+ `TabView`).
- VStack `spacing: HLSpace.lg` between major surfaces in a screen.
- VStack `spacing: HLSpace.md` between card-internal rows.
- HStack `spacing: HLSpace.sm` for badge/icon-text groups.

### 1.5 Corner radii

| Token | pt | Canonical use |
|---|---|---|
| `HLRadius.xs` | 6 | Pill/chip backgrounds, sparkline cells |
| `HLRadius.sm` | 10 | Small inset wells, skeleton placeholders |
| `HLRadius.md` | 14 | Buttons (`HLButton`), small affordances |
| `HLRadius.lg` | 18 | **`HLCard` default — every card on canvas.** |
| `HLRadius.xl` | 22 | Reserved |
| `HLRadius.xxl` | 28 | Bottom-sheet top-rounded edge |
| `HLRadius.tile` (= 16) | 16 | Dashboard tile alias (currently routes through `HLRadius.lg` due to history; lock `tile = lg` going forward) |
| `HLRadius.card` (= 20) | 20 | Canonical alias for cards — **use this in new code instead of `lg`** |
| `HLRadius.button` (= 14) | 14 | Button alias |
| `HLRadius.sheet` (= 28) | 28 | Sheet top edge |

**Concentric corners rule:** when a chip lives inside a card, its radius is at most card-radius minus inset. Today `HLCard.lg=18` + `HLBadge` capsule rendering already satisfies this.

---

## 2. Components

### 2.1 HLDashboardTile — the canonical compact card

**Reference:** `HealthLog/Screens/Dashboard/Tiles/HLDashboardTile.swift:84-106`.

This is the gold-standard tile. Every metric tile in the app reads as one of these.

Anatomy (1×1 cell inside `LazyVGrid(columns: 2, spacing: HLSpace.md)`):

```
┌──────────────────────────────────────┐  ← HLCard, padding(HLSpace.lg)
│ ◐  Gewicht           ↓               │  ← headerRow: icon (14pt, HLText.secondary)
│                                      │      + title (.hlCaption.semibold, HLText.secondary)
│                                      │      + TrendChip (monochrome, only red on adverse)
│ 72,4 kg                              │  ← valueRow: .hlMetric(28pt) HLText.primary
│                                      │      unit .hlCaption HLText.secondary
│ ╱╲╱╲╱                                │  ← sparklineRow: HLText.tertiary, height 36pt
└──────────────────────────────────────┘
```

Locked rules:
- Background: `HLSurface.secondary` (white in light, lifted-charcoal in dark).
- Corner radius: `HLRadius.lg` (18pt).
- Inner padding: `HLSpace.lg` (16pt) via `HLCard`.
- Inner VStack `spacing: HLSpace.sm` (8pt).
- Icon **never** carries per-metric tint. Always `HLText.secondary`.
- Sparkline tint always `HLText.tertiary`.
- Trend-chip color rules: `HLColor.statusBad` only on adverse trend; everything else `HLText.secondary`. Unknown trend → render nothing.
- Drill-down via `.matchedTileGeometry` (W-IMPL-MOTION-POLISH).

**Half-width vs full-width:** the grid is fixed 2-column. For "Mood + Mood-Stability" type combos, render two `HLDashboardTile`-sized cells next to each other (operator: "Mood+Stab in einer Kachel" = two adjacent half-width tiles, not one wide tile with a divider).

### 2.2 HLCard — the canonical card

`HealthLog/DesignSystem/HLCard.swift:1-45`.

```swift
HLCard(style: .standard) { /* content */ }
```

Locked behaviour:
- Padding inside: `HLSpace.lg` (16pt) all sides.
- `.frame(maxWidth: .infinity, alignment: .leading)` — cards span their column.
- Background: `HLSurface.secondary` for both `.standard` and `.elevated`; transparent for `.ghost`.
- Corner radius: `HLRadius.lg` (18pt), continuous.
- Shadow: `HLShadow.card` (elevated) / `HLShadow.cardLight` (standard). Dark-mode shadow effectively disappears against canvas; that's expected.
- Ghost: hairline stroke `HLColor.separator`, no fill.

### 2.3 HLButton

`HealthLog/DesignSystem/HLButton.swift`.

Five variants, three sizes. **All buttons in the same screen must share the same size** unless deliberate hierarchy applies (one primary CTA + one secondary).

| Variant | Background | Foreground | Stroke | Use |
|---|---|---|---|---|
| `.primary` | `.tint` filled (post-Y1: solid `HLText.primary`) | `Color.white` (auto-clamped via WCAG) | hairline | Primary CTA on a screen (Save, Verbinden, Hinzufügen) |
| `.secondary` | transparent | clamped accent (post-Y1: `HLText.primary`) | hairline 1pt @ tertiary 25% | Secondary action next to primary |
| `.outline` | transparent | clamped accent | 1.5pt accent stroke | Tertiary action, danger-cancel |
| `.ghost` | transparent | `HLText.primary` | hairline | "More options", "Show all" |
| `.destructive` | `HLColor.statusBad` | `Color.white` | hairline | Delete, sign-out, archive |

Sizes:
- `.compact`: 44pt min-height, `.hlSubhead` font.
- `.regular`: 48pt min-height, `.hlHeadline` font. **Default everywhere.**
- `.large`: 56pt min-height, `.hlTitle3` font. Primary CTA on Empty-State / Onboarding only.

**Operator-flagged anti-pattern** (Settings Advanced): three buttons in one screen at three different sizes ("Konto unwiderruflich löschen" massive vs "Audit Log öffnen" tiny vs "Passkeys verwalten" medium). Rule: **one screen, one size**. Convert all to `.regular` `HLButton(_, variant: …)` and let `variant` carry the emphasis, not the size.

### 2.4 HLSparkline / TrendChip / HLRing

- `HLSparkline`: always `tint: HLText.tertiary` on tiles, height 36pt on dashboard, height 80pt (`HLChartStyle.heightCompact`) elsewhere. Requires ≥2 points.
- `TrendChip`: glyph-only, `HLColor.statusBad` on adverse, `HLText.secondary` otherwise. No filled background.
- `HLRing` (Compliance, HealthScore): tint comes from band-derivation (`statusOK/Warn/Bad`), **not** from user-picker. Stroke width matches HLSpace.sm.

### 2.9 HLMetricTile — the unified metric tile (v0.10.0 W-Insights)

**Reference:** `HealthLog/DesignSystem/HLMetricTile.swift` + `HLRangeBand.swift`.

The ONE primitive for every metric snapshot across the app. It collapses the
three pre-v0.10.0 anatomies (`InsightsTargetTile`, `HLDashboardTile`,
`PerKindInsightCard`) into a single descriptor-driven, `Sendable`-input surface
so every tile reads at the operator's bar — the **Blood-Pressure tile is the
benchmark**: value + 30-day context + an optional target/normalcy band + a
sparkline + a per-tile AI affordance, all monochrome with color used only as a
status signal.

Anatomy (HLCard, padding `HLSpace.lg`, radius `HLRadius.lg`, inner spacing
`HLSpace.sm`):

```
┌──────────────────────────────────────────────┐
│ ◐  Weight                          ↓   ✦      │  icon(14,sec) + title(.hlCaption.semibold,sec)
│                                                │     + trend glyph (mono / red-on-adverse) + ✦ (sec)
│ 72.4 kg                                        │  value .hlMetric(28) primary + unit .hlCaption sec
│ 23 of 30 days in range · Ø 30d 72.8 kg         │  context .hlCaption tertiary (the "deep" line)
│ ╱╲╱╲╱                                          │  HLSparkline tint HLText.tertiary, height 36
│ ▟▟▟░░▟▟ Target 71–74 kg                        │  OPTIONAL range band (only if reference range)
│ ● In range                                     │  OPTIONAL status badge (signal-color dot only)
└──────────────────────────────────────────────┘
```

Locked rules:
- **Range band** (`RangeBand` + `RangeBandRow`): the BP-level "deep" element,
  generalized from `BPStatusCard.bpInTargetBar` — an 8 pt status-toned rail
  (mono track `HLColor.backgroundEleva`, fill = `% of last 30 days in target`,
  tone `statusOK ≥80 · statusWarn 50–79 · statusBad <50`) + a one-line
  `Target lo–hi unit` label. Tiles without a configured range omit it (exactly
  like BP omits it when `targets == nil`).
- **Data-only contract:** a tile renders ONLY when it has data. No em-dash card,
  no `FeatureDisabledCard` placeholder. `compact` (half-pairs) drops the context
  line + range band so adjacent tiles align on the value-row baseline.
- **Color discipline:** the ONLY color is the in-range dot, the adverse trend
  glyph, and the range-band fill — all from the signal palette. `✦` is
  `HLText.secondary`, never purple. Icon never carries a per-metric tint.
- **Motion:** value digits roll via `.contentTransition(.numericText())` +
  `.snappy(0.25)`; range-band fill animates width on `.snappy(0.3)` (static
  under reduce-motion).
- **Per-tile AI (`✦` → sheet):** when the assistant is configured
  (`assistant.trend`) AND the tile maps to a `MetricKind`, a `✦` renders in the
  header. Tapping it presents `MetricAIExplainerSheet` (`.medium` detent,
  Home-Compliance dismissal) wrapping the on-device
  `TrendObservationsService.observe(...)` output + a "What the assistant looked
  at" citation + an "On your device" provenance pill + "Ask the coach about
  this". AI is contextual on-tap — NEVER an always-on inline wall.
- **Universal tap→chart:** every metric-shaped tile is wrapped in a
  `NavigationLink` to `ChartDetailScreen` (a11y id `insights.tile.<type>`,
  hint "Double-tap to open detail view").

**Reusability (W-Mood):** `HLMetricTile` + `RangeBand`/`RangeBandRow` are
self-contained DesignSystem primitives — they import no Insights-screen state.
The Mood-detail surface constructs an `HLMetricTile` from its own view-model and
gets the identical anatomy.

### 2.5 Avatar / Gravatar

`HLProfileAvatar` (round, Gravatar-fetch + initials-fallback). Reference: `DashboardHeader.swift:46-53`.

Locked usage:
- **Inline with the screen title in the header row.** Right-aligned, 44pt diameter. Tap pushes ProfileScreen.
- Hero size in ProfileScreen: 88pt (`profile.hero` block).
- Never inside a card chrome; lives only at the screen-header level.
- `HLProfileAvatar(size: 44, email: …, initials: …)` — no border ring, no decorative outline.

### 2.6 Bottom-sheet — Home-Compliance pattern (canonical)

**Reference:** `AnstehendeEinnahmenSheet.swift`.

Locked rules:
- Presented via `.sheet(isPresented:) { … }` from the parent.
- `.presentationDetents([.medium, .large])` (operator likes both; sheet grows when the day is full).
- `.presentationDragIndicator(.visible)` — the grabber is the dismiss affordance.
- `.presentationBackground(HLColor.surface)` — opaque card surface, no transparency.
- Inside: `NavigationStack` with `navigationTitle` + `navigationBarTitleDisplayMode(.inline)`.
- **NO `cancellationAction` button (`Abbrechen`).**
- **NO `topBarTrailing` X-button on the title bar.** (Today's `AnstehendeEinnahmenSheet` has one — Y2 removes it.) The drag-indicator + swipe-down is the only dismiss path.
- **NO `Fertig` confirm button.** (Today's `HealthScoreDetailSheet` has one — Y2 removes it.)
- Subtitle row at top: `.hlSubhead` `HLText.secondary` — short live counter ("Heute, 2 von 4 noch offen").
- Empty state: card with SF Symbol + `.hlHeadline` title + `.hlSubhead` body, all monochrome.
- Row layout: `HLCard(style: .standard) { HStack(spacing: .md) … }` per intake, action buttons are pill-capsule with `statusOK` tint at 15% opacity (only retained color in the sheet because it's a status confirmation).

### 2.7 Empty states

Pattern: small SF Symbol (28pt, `.regular` weight, `HLText.tertiary`) + headline (`.hlHeadline`, `HLText.primary`) + body (`.hlSubhead`, `HLText.secondary`) + optional CTA (`HLButton(.primary)`).

Reference: `EmptyMedicationsState` in `MedicationsScreen.swift:291-325`.

Rules:
- **Never** a giant centered icon with no copy.
- **Never** a "0 entries" string.
- Always frame the message as a guide forward ("Erfasse dein erstes …").

### 2.8 Charts — time-range pills + Min/Max/Median pills

Pattern reference: `ChartDetailScreen.swift` (StatsRow, RangePicker, Chart marks).

Locked rules:
- Time-range segmented picker: native `.pickerStyle(.segmented)`. Background `HLMaterialBackground()` — the system handles dark/light.
- **No `Color.blue` / `.systemBlue` selection tint.** Operator: "Min/Max/Median + time-range pills dunkelblau, sollen schwarz". This means the picker selection chip must inherit the chrome accent, which post-Y1 routes to `HLText.primary`. Achieved by removing the `.tint(...)` override at the screen root (it's currently inherited from the deprecated accent picker).
- `StatBox` (Min/Ø/Max/Median): pill-style, background `HLSurface.tertiary` (currently `HLColor.surface` — equivalent in dark, but lock to `tertiary` for new code). Foreground `HLText.primary` for value, `HLText.secondary` for label, `HLText.tertiary` for unit.
- Chart marks: `HLChartTints.series` (post-Y1 = `HLText.primary`); thresholds dashed red/green via `HLChartTints.thresholdHigh / thresholdLow`. Grid `HLChartGrid.lineOpacity` (0.10) on `HLText.primary`. Axis labels `.hlCaption` `HLText.secondary`.
- MDR PK chart (`MDRGatedDrugLevelSection`): post-Y1 the AreaMark + LineMark + PointMark + syringe glyph all paint `HLText.primary` (no purple).

---

## 3. Layout patterns

### 3.1 Screen header

Two flavours.

**Flavour A — DashboardHeader inline (no NavigationBar title):**
- Reference: `DashboardHeader.swift`.
- Layout: `HStack { VStack { greeting .hlLargeTitle + date .hlSubhead .secondary }; Spacer; Avatar(44pt) }`.
- Used on Dashboard. The avatar pushes ProfileScreen. The screen does NOT set `.navigationTitle`.

**Flavour B — MoreHeader inline (NavigationBar title omitted):**
- Reference: `MoreScreen.MoreHeader:213-249`.
- Layout: `HStack { Text("Mehr") .hlLargeTitle; Spacer; GearButton(44pt) }`.
- The gear button rules (operator-locked): **NO circle around it.** White symbol, same size as the "Mehr" title text. Currently the gear is `Image(.gearshape).font(.system(size: 18))` inside a `HLSurface.secondary` circle — Y4 removes the circle backplate, swaps to `.foregroundStyle(HLText.primary)`, and bumps font to `.hlLargeTitle` so visual size matches the title.

**Flavour C — Standard NavigationStack:**
- Used for pushed screens (Settings sub-screens, MedicationDetailScreen, ChartDetailScreen, MeasurementListScreen).
- `.navigationTitle("…")` + `.navigationBarTitleDisplayMode(.inline)`.
- No custom hero in the screen body — the navbar carries the title.

### 3.2 List rows

Single-line discipline. Two-line allowed only when the secondary line is supplementary (dose · time-pattern), never a duplicate.

Locked anatomy:
```
HStack(spacing: HLSpace.md) {
    icon  // SF Symbol, .hlSubhead or 18pt semibold, HLText.secondary
    VStack(alignment: .leading, spacing: HLSpace.xxs) {
        Text(title) .hlSubhead.weight(.semibold) HLText.primary  .lineLimit(1)
        Text(subtitle) .hlCaption HLText.secondary .lineLimit(1)  // optional
    }
    Spacer(minLength: HLSpace.sm)
    trailing affordance (chevron / chip / button)
}
.padding(.vertical, HLSpace.sm)
```

**Anti-patterns the operator called out:**
- Befunde row "Assistent - Befund + Zwischengespeichert" wrapping to 2 lines: **shorten** to "Assistent · Zwischengespeichert" single line.
- Medikamente row showing per-row checkboxes: **remove**; tap whole row → MedicationDetailScreen → quick-mark lives in detail.
- Trulicity Plan "08:00 Mittwoch": **rewrite** as "Wöchentlich Mittwoch 08:00" single line in the ScheduleSection.

### 3.3 Section grouping

Two patterns:

**Pattern A — HLSettingsCard for grouped settings:**
- Used in all `Settings/Sub/*Screen.swift`.
- Icon (chip) + title + optional subtitle + content slot + optional footer.

**Pattern B — Flat list with uppercase section header:**
- Used in MedicationsScreen, MedicationDetailScreen, MeasurementListScreen.
- Header: `Text("HEUTE").font(.hlFootnote.weight(.semibold)).foregroundStyle(HLText.secondary).textCase(.uppercase).tracking(0.5)`.
- Rows render directly on screen surface (no per-row card wrapper).

Operator rule: **stick to one pattern per screen.** Mixing creates the "klotzig" feel.

### 3.4 Tile grid rhythm

Dashboard `.cards` layout:
- 2-column `LazyVGrid` with `spacing: HLSpace.md` (12pt) between cells.
- Cells are square-ish (~170pt on iPhone 16 Pro).
- Operator wants every Ziele-Metric (Blutdruck/Gewicht/Ruhepuls/Mood/Mood-Stab/Compliance/Steps/d) on the same tile-style. Mood + Mood-Stab combine as two adjacent half-width tiles (not one merged tile).

Insights screen (v0.10.0 W-Insights — the four-zone IA):
- Single-column `VStack` with `spacing: HLSpace.lg` (16pt) between major surfaces.
- **Zone 1 — Hero:** ONE on-device "Today at a glance" briefing card with a loud
  three-state provenance row (`lock.iphone` "On your device" / `icloud` "From
  your account" / `chart.bar` "From your data") + whole-card tap → AskCoach
  (`ellipsis.message` hint). The second hero (`AskCoachHeroCard` body card) is
  gone — AskCoach collapses to the header coin + the Hero tap.
- **Zone 2 — Dynamics** (`InsightsDynamicsZone`, only when present): alarming
  alerts (`.danger`/`.warning`, rendered OUTSIDE the AI gate — deterministic
  server findings) + "Notable this week" trend chips (`keyFindings` with
  `tone == .watch`, capped at 3, tap → that metric's chart). Signal-only — never
  gamified, never a streak banner, silent when there is no signal.
- **Zone 3 — Tiles:** the unified `HLMetricTile` grid (§2.9) + BMI (tap →
  `BMIDetailScreen`) + BP (tap → BP chart) + the long-tail. Every tile data-only,
  tap→chart, `✦`→AI explainer.
- **Zone 4 — Go deeper:** Trends + Correlations footer links + data-quality
  footnote.
- **Removed in v0.10.0:** the duplicate Health Score (lives on Dashboard), the
  always-on `SummaryCard`, the inline `TrendObservationCard` AI wall, and the
  `FeatureDisabledCard` placeholder.

---

## 4. Interaction

### 4.1 Sheet presentation

Three classes of sheets in the app, listed in priority of "use the Home-Compliance pattern" affinity:

1. **Lightweight contextual sheets** — AnstehendeEinnahmenSheet, MoodQuickEntrySheet, CapturePickerSheet, AIConsentSheet, AchievementDetailSheet, BenchmarkSourceSheet. **All convert to the Home-Compliance pattern in Y2.** No `Abbrechen`, no X-button, no `Fertig` — drag-indicator only.

2. **Edit forms** — AddMedicationSheet, EditMedicationSheet, PenInventoryEditSheet, SideEffectLogSheet, TitrationStepEditSheet, MeasureSheetView, EditProfileScreen-as-sheet. These keep `cancellationAction` ("Abbrechen") + `confirmationAction` ("Speichern") in the toolbar — they're forms, the operator needs an explicit confirm/dismiss. **Pattern stays.**

3. **Full-screen-equivalent sheets** — DeleteAccountScreen, HealthScoreDetailSheet, MiniCoachSheet, AskCoachSheet, PhotoOfMedSheet. These should adopt Home-Compliance dismissal (drag-only) **unless** they require an explicit confirm action (DeleteAccount: keeps "Schließen" because of the destructive flow). Y2 sweeps these case-by-case.

### 4.2 Navigation

- Tabs: native iOS-18 `TabView` (in `AuthenticatedShell`). Center tab is the Erfassen-sheet trigger.
- Push: `NavigationLink(value:)` + `.navigationDestination(for:)` (typed routes — `MoreRoute`, `AppRouter.morePath`).
- Drill-down detail: `navigationDestination(item:)` with `Identifiable` payload (see `DashboardScreen.drillDown`).
- Modal: `.sheet(isPresented:)` for one-shot; `.sheet(item:)` for typed.
- **Never** wrap a pushed view in another `NavigationStack` — operator-flagged `MoreScreen` regression history.

### 4.3 Haptics

Pattern: declarative `.sensoryFeedback(_, trigger:)`.

| Trigger | Feedback |
|---|---|
| Button tap (HLButton, HLPressable) | `.selection` |
| Save success | `.success` |
| Save error | `.error` |
| Save queued offline | `.success` (with banner) |
| Pull-to-refresh complete | `.success` |
| Chart scrub | `.selection` on selection-change |

No raw `UIImpactFeedbackGenerator` in new code.

### 4.4 Animations

Reference: `HLMotion`.

| Token | Use |
|---|---|
| `HLMotion.spring` (0.35s, 0.78 damping) | State transitions |
| `HLMotion.snap` (0.22s) | Affordance feedback |
| `HLMotion.smooth` (0.18s) | Opacity crossfades |
| `HLMotion.progress` (0.6s easeOut) | Ring fills |

**Perceptual Budget:** all transitions in 200-300ms (per PROJECT_GUIDE.md). No rubber-band, no spring-too-bouncy. ChartDetailScreen's `.snappy(0.35)` is the upper bound for a re-render.

Dashboard parallax (`HLMotion.parallaxRate=1.3`) honoured only when not Reduce-Motion.

---

## 5. Anti-patterns to remove from existing code

Sourced from the operator audit + drift matrix (§6). Each entry maps to a specific finding-ID consumed by Y1–Y7.

### 5.1 Color / chrome

- **AP-001 — Raw `HLColor.purple/cyan/pink/orange/purpleDeep` in screens** (in-app, non-onboarding). Route through `HLText.primary` (chrome) or `HLText.secondary` (icons) or `.tint`-inheritance.
- **AP-002 — Color-coded source pills** in `ChartDetailScreen.SourcesRow` (Withings=cyan, Import=orange). Mono `HLText.secondary` on all source labels; provenance lives in the label text.
- **AP-003 — Gradient hero cards** (Coach: purple→pink). Replace with mono `HLSurface.secondary` card carrying SF Symbol + headline + subhead. **Y4.1 exception:** AskCoach Hero + Collapsed Coin reverted to the gradient on operator-direction — see §5.9 Exceptions.
- **AP-004 — `Color.accentColor` reads** when the picker is deprecated. Replace with `HLText.primary` for chrome and remove from non-button consumers.
- **AP-005 — `dunkelblau` on time-range / Min/Max/Median pills** — caused by `.tint(.systemBlue)` when accent picker = `.systemBlue`. Removed once accent picker is gone.

### 5.2 Sheet chrome

- **AP-006 — X-button top-right** on `AnstehendeEinnahmenSheet` (line 68-77). Remove.
- **AP-007 — `Fertig` confirm-button** on `HealthScoreDetailSheet:62`. Remove.
- **AP-008 — `Abbrechen` cancel-button** on `CapturePickerSheet:139-146`. Remove.
- **AP-009 — Inconsistent presentation background** — some sheets pass `HLColor.surface`, some don't. Lock to `HLColor.surface` on all Home-Compliance-pattern sheets.

### 5.3 Hierarchy / typography

- **AP-010 — Title smaller than meta** — Settings Integrations Apple Health card: `Verbindungsstatus verbunden` (.hlBody) reads larger than `Apple Health` chip-title rhythm. Drift between `.hlBody` body rows and `.hlSubhead` header gives reverse hierarchy.
- **AP-011 — Description smaller than caption** — Settings → AI provider: `Lese-/Schreibzugriff relativ` rendered as caption while a subhead-sized button label sits beside it.
- **AP-012 — Two-line list rows** where copy could be single-line (Befunde / Medikamente Plan row).

### 5.4 Button sizing

- **AP-013 — Mixed button sizes within one screen.** Settings Advanced has `.regular` HLButton + plain Button + chevron-row mixed. Unify to one variant per screen.

### 5.5 Compliance Haken logic

- **AP-014 — Empty `circle.dotted` vs Haken** — operator: "currently Haken for not-taken too — confusing". Today's `IntakeHistoryRow.statusIcon` (line 88-116) renders `circle.dotted` for "pending past" + auto-skip for >24h — operator wants empty circle by default + green checkmark **only** after explicit Genommen tap. Verify the `pending` case truly renders `circle.dotted` (empty circle) — currently it does, so this is more a clarification on `IntakeRow` (today) where the `.pending` case renders `EmptyView` (line 571) — should render a tappable empty circle here too.

### 5.6 CRUFT from prior eras

- **AP-015 — `Color.accentColor.opacity(0.18)` chips** in old surfaces (AchievementDetailSheet, AchievementMedallion, MedicationQuickIntakeSheet, EditMedicationSheet weekday picker). Verify each: does the operator see these? Most are gated behind `Achievements` (which the operator does see). Convert to mono.
- **AP-016 — Coach hero gradient** — purple→pink with white spotlight. **Y4.1 reversal:** operator restored the gradient as the AI-brand-moment exception — see §5.9 Exceptions.
- **AP-017 — Profile "top color bg"** — see ProfileScreen.heroSection (line 53-83). The `listRowBackground(Color.hlBackground)` paints a different shade than the canvas. Unify to canvas surface, no tinted hero strip.

### 5.7 Hero / avatar layout

- **AP-018 — Avatar in toolbar slot** instead of inline header (only Dashboard does this correctly already; Insights tab puts the Coach-coin in `topBarTrailing`). The Insights surface should pull `AskCoachCollapsedCoin` into the inline header pattern (analogous to Dashboard avatar), not the toolbar.
- **AP-019 — Profile "Profil bearbeiten" duplicate** — ProfileScreen renders `heroName + email + edit-row-with-chevron`. Operator: "looks doppelt; tap on 'Profil bearbeiten' should open edit, no separate row needed". Y6 collapses the hero so the whole hero is the tappable affordance.

### 5.8 Routing / not-wired

- **AP-020 — Trulicity Nebenwirkungen + Pen-Bestand** — verify reachable. After audit: both ARE wired (`MedicationDetailScreen.body:74-83` mounts `SideEffectsLogbookSection` + `PenInventoryView` when `isGLP1Recognised`). Operator may have hit them on a non-recognised drug — Y3 adds a "Manual mode" affordance + clarifies the `UnknownGLP1BrandSection` copy.

### 5.9 Exceptions to the monochrome rule (operator-approved)

The signal-only colour palette and the §1.2 ban on `HLColor.purple` /
`HLColor.pink` in screen chrome admit **one** scoped exception: the
AskCoach surfaces. These two views are the app's AI-brand-moment —
the visual analogue of Apple Intelligence's iridescent surfaces — and
the operator explicitly directed (2026-05-23, post-Y4) that they get
to keep the saturated gradient + white chrome to read as a deliberate
brand banner against the otherwise mono dashboard rhythm.

**Files covered by the exception:**

- `HealthLog/Screens/Coach/AskCoachHeroCard.swift`
- `HealthLog/Screens/Coach/AskCoachCollapsedCoin.swift`

**Permitted colour usage in those files only:**

| Token | Purpose | Constraint |
|---|---|---|
| `HLColor.purple` (`#BD93F9`) | Gradient start, top-leading | Only inside a `LinearGradient` pair with `HLColor.pink`. |
| `HLColor.pink` (`#FF79C6`) | Gradient end, bottom-trailing | Only inside the same gradient pair. |
| `Color.white` | Headline + subhead chrome, `sparkles` glyph, hairline inner-stroke, CTA pill text + chevron | Only as the contrast device against the gradient base. |
| `Color.white.opacity(0.78)` | Subhead | Specific 78% value locked so the WCAG AA contrast against the gradient stays compliant at 15pt. |
| `Color.white.opacity(0.18)` | Inner-highlight stroke | Hairline only. |
| `Color.white.opacity(0.16)` | Radial spotlight at `.topTrailing` | Spotlight only — no other surface uses this token. |
| `Color.white.opacity(0.32)` | CTA-pill capsule strokeBorder | Pill only. |
| `Color.white.opacity(0.22)` | xmark secondary-palette fill | Dismiss button only. |
| `.ultraThinMaterial` | Dismiss-X backplate Circle, CTA-pill capsule fill | Glass-on-color treatment. |

**SwiftLint:** both files carry the `// swiftlint:disable forbidden_color`
waiver at the top with an explanatory comment block describing the
exception. Any **other** screen file in the app that introduces
`Color.white` / `HLColor.purple` / `HLColor.pink` still trips the lint
rule — the waiver is scoped to those two files only.

**Accessibility:** the gradient surface passes WCAG AA contrast against
the white 22pt-bold headline + 15pt 78%-white subhead. Decorative
spotlight overlay + sparkles glyph carry `.accessibilityHidden(true)`.

**Future drift defence:** if a third surface ever needs to claim the
AI-brand exception, it must be added explicitly to this section and
file the operator-direction quote next to it. Drift onto any non-AI
surface (Settings hero, Profile, etc.) is a defect and reverts to
mono per AP-001 / AP-003.

---

## 6. Per-screen drift matrix

Format: `FINDING-ID — file:line — drift type — fix direction`.

### 6.1 Dashboard — REFERENCE (no findings, locks gold standard)

- All tile chrome already mono. Compliance ring keeps `settingsStore.preferredTint.color` → after Y1: `HLText.primary` or band color from snapshot.

### 6.2 AnstehendeEinnahmenSheet (`HealthLog/Screens/Dashboard/AnstehendeEinnahmenSheet.swift`)

- **D-001 — line 68-77 — SHEET — `topBarTrailing` X-button must be removed**; drag-indicator is the dismiss.
- **D-002 — line 145-176 — LAYOUT — IntakeRow uses `HLCard(.standard)` per row** + `Circle().fill(HLColor.surfaceElevated)` for icon backplate; convert to flat-row (like POLISH-MED) inside a single outer card, or keep cards but drop the per-row icon backplate.
- **D-003 — line 149 — COLOR — `.foregroundStyle(.tint)` on pill icon** routes through accent picker. Post-Y1: `HLText.primary`.
- **D-004 — line 198-215 — BUTTON — Inline pill button "Genommen"** uses `HLColor.statusOK.opacity(0.15) + 0.3 stroke`. Lock as canonical signal-color usage; this is correct.

### 6.3 ComplianceRingCard (`HealthLog/Screens/Dashboard/ComplianceRingCard.swift`)

- **D-005 — line 93 — COLOR — `tint: settingsStore.preferredTint.color`** on `HLRing`. Post-Y1: derive tint from snapshot.ratio (statusOK ≥0.9, statusWarn 0.5-0.9, statusBad <0.5) so the ring is informative.

### 6.4 HealthScoreTile (`HealthLog/Screens/Dashboard/HealthScoreTile.swift`)

- **D-006 — line 137-139 — COLOR — `bandColor` uses statusOK/Warn/Bad** for ring tint — KEEP, this is canonical signal use.
- **D-007 — line 138 — CRUFT — `case nil: Color.accentColor`** fallback. Post-Y1: `HLText.tertiary`.
- **D-008 — line 156-202 — LAYOUT — DeltaChip uses status colors at .opacity(0.18) as background pills** — operator likes signal use here; KEEP.

### 6.5 InsightsScreen (`HealthLog/Screens/Insights/InsightsScreen.swift`)

- **D-009 — line 70-75 — LAYOUT — AskCoachCollapsedCoin in `topBarTrailing`** — operator: "kollabiert → Gravatar-style avatar (round, scrolls), not fix-top". Move to inline header like Dashboard avatar. Coin scrolls with content.
- **D-010 — line 391-393 — COLOR — `sparkles` icon `.foregroundStyle(.tint)`** in SummaryCard. Post-Y1: `HLText.primary`.
- **D-011 — line 397 — COLOR — `HLBadge(providerLabel, tone: .purple)`** — convert to `.neutral`.
- **D-012 — Correlations panel** — operator: "Zusammenhänge → eigene Subpage via footer-link". Currently rendered inline at line 281-283. Y4 extracts to `CorrelationsScreen` + adds a "Mehr anzeigen" footer-link in this slot.

### 6.6 PerKindInsightsBlock (`HealthLog/Screens/Insights/PerKindInsightsBlock.swift`)

- **D-013 — ✅ CLOSED (v0.10.0 W-Insights, R2 Phase D)** — the long-tail
  "Weitere Werte" block no longer renders its own `PerKindInsightCard` anatomy;
  it now renders through the unified `HLMetricTile` (§2.9) — every long-tail kind
  is a tile with value + context + sparkline + tap→chart + `✦` AI explainer.
- **D-014 — ✅ CLOSED (v0.10.0 W-Insights, R2 Phase D)** — typography drift is
  gone: the long-tail follows `HLMetricTile` (= `HLDashboardTile`) typography
  exactly now that it routes through the same primitive.

### 6.7 AskCoachHeroCard (`HealthLog/Screens/Coach/AskCoachHeroCard.swift`)

- **D-015 — line 127-144 — COLOR — purple→pink LinearGradient + white spotlight** — banned in v2. Rebuild as `HLSurface.secondary` card with `sparkles` SF Symbol (24pt, `HLText.primary`), `.hlTitle3` headline, `.hlSubhead` `HLText.secondary` subhead, no CTA pill (whole card is tappable). Drop `forbidden_color` SwiftLint waiver.
- **D-016 — line 99-119 — LAYOUT — Dismiss-X top-right** stays only because the operator wants a one-tap "fold into coin" affordance. KEEP, but flat `xmark` glyph at `HLText.tertiary`, no `ultraThinMaterial` backplate, no white tint.

### 6.8 AskCoachCollapsedCoin (`HealthLog/Screens/Coach/AskCoachCollapsedCoin.swift`)

- **D-017 — line 47 — COLOR — same purple→pink gradient** — convert to `Circle().fill(HLSurface.secondary)` with `sparkles` glyph `HLText.primary`.

### 6.9 MedicationsScreen (`HealthLog/Screens/Medications/MedicationsScreen.swift`)

- **D-018 — line 433-466 — LAYOUT — "heute" section** — operator: "Medikamente tab: 'heute' section komplett weg (nur 'Aktive Medikamente')". Today's TodayTimelineSection renders an uppercase "HEUTE" header + intake rows. Remove entirely; per-medication tap goes to detail where intake state lives.
- **D-019 — line 86-94, 235-260 — INTERACTION — Per-row quick-mark callback `onQuickMark` + leading-✓** — operator: "rows: per-row checkboxes weg, tap → detail → take action there". Remove `MedicationQuickMarkButton` from `ActiveMedicationRow`. Row tap → MedicationDetailScreen.

### 6.10 ActiveMedicationRow (`HealthLog/Screens/Medications/ActiveMedicationRow.swift`)

- **D-020 — line 50 — COLOR — `Image(systemName: "pills.fill").foregroundStyle(Color.accentColor)`** — post-Y1: `HLText.primary` for active, `HLText.tertiary` for inactive.
- **D-021 — line 78-82 — INTERACTION — MedicationQuickMarkButton inline** — remove per D-019.

### 6.11 MedicationDetailScreen (`HealthLog/Screens/Medications/MedicationDetailScreen.swift`)

- **D-022 — line 276-285 — COLOR — Hero `syringe.fill` in `Circle().fill(Color.accentColor.opacity(HLOpacity.surfaceTintStrong))`** + `.foregroundStyle(.tint)`. Post-Y1: glyph `HLText.primary`, circle `HLSurface.tertiary`.
- **D-023 — line 295-299 — COLOR — `HLBadge(drug.inn, tone: .purple)` + `tone: .info`** — convert to `.neutral`.
- **D-024 — line 442, 451, 462 — COLOR — Schedule section clock/calendar/repeat icons `.foregroundStyle(.tint)`** — post-Y1: `HLText.secondary`.
- **D-025 — line 484-485 — LAYOUT — ScheduleSection timesLabel** renders `"08:00 · 14:00"`. Operator wants "Wöchentlich Mittwoch 08:00" rewrite. For schedules with weekdays+times: build single line `"Wöchentlich {weekday} {HH:mm}"`. For multiple weekdays: `"Wöchentlich {weekday1, weekday2} {HH:mm}"`. For daily: `"Täglich {HH:mm}"`. Y3 owns this.
- **D-026 — line 406-407 — COLOR — "Mehr laden" Button `.foregroundStyle(.tint)`** — post-Y1: `HLText.primary`.
- **D-027 — Verlauf section (line 360-420) — LAYOUT — operator: "kein X-Salat, % in-time Compliance metric ergänzen"**. The IntakeHistoryRow today shows a clean status-icon column (no X-salat issue I can identify in current code — verify on simulator). Add per-medication `% in-time` summary chip above the Verlauf list (computed from last 30 intakes: taken-within-2h-of-scheduled / total).

### 6.12 MDRGatedDrugLevelSection (`HealthLog/Screens/Medications/MDRGatedDrugLevelSection.swift`)

- **D-028 — line 245 — COLOR — AreaMark `LinearGradient([Color.accentColor.opacity(0.5), .opacity(0.08)])`** — post-Y1: `[HLText.primary.opacity(0.4), .opacity(0.06)]`.
- **D-029 — line 254 — COLOR — LineMark `.foregroundStyle(HLColor.purpleDeep)`** — operator: "Trulicity Wirkstoffspiegel chart: Dracula-Lila — fix monochrom". Post-Y1: `HLText.primary`.
- **D-030 — line 265, 269 — COLOR — PointMark + syringe annotation `HLColor.purpleDeep`** — `HLText.primary`.
- **D-031 — line 273 — COLOR — RuleMark "Jetzt" `HLColor.textTertiary.opacity(0.6)`** — KEEP, already mono.
- **D-032 — line 109 — COLOR — `lock.shield.fill` `.foregroundStyle(.tint)`** — post-Y1: `HLText.secondary`.

### 6.13 GLP1 Side Effects + Pen Inventory + Titration + InjectionSite

- **D-033 — `SideEffectsLogbookSection.swift:57, 71-77` — COLOR — `plus.circle.fill` `.foregroundStyle(.tint)`** — `HLText.primary`. Section header rhythm correct.
- **D-034 — `TitrationLadderSection.swift:64, 129` — COLOR — Add-button `.tint` + `info.circle .foregroundStyle(HLColor.cyan)`** — post-Y1: `HLText.primary` + `HLText.secondary`.
- **D-035 — `PenInventoryView.swift:63, 109` — COLOR — Add-button `.tint` + syringe glyph `.tint`** — `HLText.primary` for both, with the syringe slot mirroring HLDashboardTile chrome.
- **D-036 — `InjectionSitePicker.swift:41, 213, 220` — COLOR — `HLColor.cyan` suggested-site fill + dot** — convert to `HLText.tertiary` fill, `HLText.primary` outline for selected/suggested.
- **D-037 — Trulicity routes — verification needed** — these sections ARE mounted by `MedicationDetailScreen.body:69-83` gated on `isGLP1Recognised`. Operator may have hit them on a brand the catalog doesn't recognise (renders `UnknownGLP1BrandSection`). Y3 audits + adds "Manual mode" fallback so non-recognised brands still get journal-only sections (without the PK chart).

### 6.14 CapturePickerSheet (`HealthLog/Screens/Capture/CapturePickerSheet.swift`)

- **D-038 — line 139-147 — SHEET — `cancellationAction` Abbrechen button** — operator: "Abbrechen-Button left → weg". Remove; drag-indicator is the dismiss path.
- **D-039 — line 192-193 — COLOR — Row icon `.foregroundStyle(.tint)`** — post-Y1: `HLText.primary`.
- **D-040 — line 137 — LAYOUT — `navigationBarTitleDisplayMode(.inline)`** — KEEP. Operator wants the sheet to feel like Home-Compliance.
- **D-041 — line 165-167 — SHEET — `sheetBackground` is `HLSurface.primary`** — KEEP. Already canonical.

### 6.15 MoreScreen (`HealthLog/Screens/Settings/MoreScreen.swift`)

- **D-042 — line 233-244 — LAYOUT — Gear-icon in MoreHeader has a circle backplate** (line 238). Operator: "Kreis weg, weißes Symbol, gleiche Größe wie 'Mehr'-Title". Remove `.background(HLSurface.secondary, in: Circle())` + the `.overlay { Circle().stroke(...) }` (line 239-242), foreground stays `.tint` (post-Y1: `HLText.primary`), bump font from `.system(size: 18)` to `.hlLargeTitle` to match the title size.
- **D-043 — line 159-171 — LAYOUT — LOINC-Übersicht in "Klinik & FHIR" section** — operator: "LOINC-Übersicht → Erweiterte Einstellungen". Y4 moves this row out of MoreScreen and into SettingsAdvancedScreen as a nav-link.
- **D-044 — Sign-out + Konto löschen not present in MoreScreen** — operator: "Abmelden + Konto löschen → 'Sicherheit'-Kategorie unten". Today these live in SettingsScreen at the bottom. Operator wants them surfaced at the bottom of MoreScreen too, in a "Sicherheit"-section (or simply renamed "Sicherheit & Konto"). Verify with operator before implementing; if confirmed, Y4 adds the section.

### 6.16 SettingsScreen (`HealthLog/Screens/Settings/SettingsScreen.swift`)

- **D-045 — line 47-100 — LAYOUT — `Form` rendering with rounded sections** — operator likes the visual layout. KEEP.
- **D-046 — line 242, 264 — COLOR — Sign-out + Delete iconTint `HLColor.statusBad`** — KEEP, canonical signal-color usage.
- **D-047 — Hub row icons all in `Color.accentColor`** via HLSettingsRow chip — post-Y1: `HLText.primary` mono.

### 6.17 SettingsDevicesScreen (`HealthLog/Screens/Settings/Sub/SettingsDevicesScreen.swift`)

- **D-048 — line 90-108 — LAYOUT — Gekoppelte Geräte card** — operator: "white-on-white card" on light mode. Card surface `HLSurface.secondary` (white in light) inside another card via `HLSettingsPage` → `HLSettingsCard` (also `HLSurface.secondary`). Nested card on same surface = invisible separation. Y5: either drop the outer card wrapper on this screen OR convert paired-list rows to recessed `HLSurface.tertiary` wells.
- **D-049 — Logo issue — line 159 — IMAGERY — `heart.text.square.fill` SF Symbol** as the device-row icon. Operator: "Geräte: kein Logo (graue Fläche)". A paired Omron BP cuff should show a recognisable glyph; if `SpeziDevices` exposes a brand asset, use it. Otherwise the SF Symbol must be `cardstack` or similar that clearly reads "device". Y5 investigates.
- **D-050 — line 182-185 — BUTTON — `Gerät hinzufügen` uses raw `.buttonStyle(.borderedProminent)`** instead of HLButton. Convert to `HLButton(_, variant: .primary, size: .regular)`.

### 6.18 SettingsIntegrationsScreen (`HealthLog/Screens/Settings/Sub/SettingsIntegrationsScreen.swift`)

- **D-051 — line 51-58 — LAYOUT — Apple Health card title hierarchy** — operator: "Apple Health Import title kleiner als open-button". The `HLSettingsCard.title` is `.hlSubhead.weight(.semibold)` (per HLSettingsCard internals) while the body's `HLButton` label is `.hlHeadline`. Hierarchy reversed. Either bump `HLSettingsCard.title` to `.hlTitle3` (consistent with HLDashboardTile) or shrink `HLButton.size` to `.compact` here.
- **D-052 — line 64-74 — TYPO — `HLStatusPill` "Verbunden" pill** size vs surrounding text — operator: "Verbindungsstatus verbunden zu groß". Pill rendered at `.hlSubhead` weight; should be `.hlCaption` to match other status meta.
- **D-053 — line 80-83 — TYPO — `Lese-/Schreibzugriff relativ` zu klein** — `subtitle` of HLSettingsCard renders at `.hlCaption`. Should be `.hlSubhead` for body-readability.
- **D-054 — line 89-96, 117-127, 129-138 — BUTTON — Three different HLButton sizes implicitly via `variant` / icon** — unify to `.regular`, vary only by `variant` (primary for Connect, secondary for Sync, ghost for diagnostics).

### 6.19 SettingsAdvancedScreen (`HealthLog/Screens/Settings/Sub/SettingsAdvancedScreen.swift`)

- **D-055 — line 96-122 — LAYOUT — "Konto unwiderruflich löschen" giant card** vs **D-056 — "Audit-Log öffnen" tiny row** (line 67-90) vs **D-057 — "Passkeys verwalten" plain row** (line 48-64). All three at different visual weights. Operator: "unify". Convert each to a `HLSettingsCard` with consistent `subtitle + content slot + one HLButton(.regular)` rhythm. The "Konto löschen" card stays a hint-card (it's a redirect, not the action itself) but uses `HLButton(.regular, variant: .secondary)`.

### 6.20 SettingsCoachScreen (`HealthLog/Screens/Settings/Sub/SettingsCoachScreen.swift`)

- **D-058 — line 84 — COLOR — `.foregroundStyle(HLColor.purple)`** — `HLText.primary`.

### 6.21 ProfileScreen (`HealthLog/Screens/Profile/ProfileScreen.swift`)

- **D-059 — line 78 — COLOR — `.listRowBackground(Color.hlBackground)`** on hero section — operator: "top color bg → weg". The hero strip currently paints `HLColor.background` while the surrounding inset-grouped List sits on `HLSurface.primary`. Same hex in dark (both #16171C/#101113), but different in light. Lock to `Color.clear` (transparent) so the hero blends with the canvas.
- **D-060 — line 87-100 — LAYOUT — `profileSection` with NavigationLink "Profil bearbeiten"** + hero already showing the avatar/name/email. Operator: "Name / Email / Profil bearbeiten + right-arrow — looks doppelt". Y6 collapses: hero section becomes the tappable affordance (whole hero wrapped in `NavigationLink { EditProfileScreen() }`); removes the separate "profileSection".
- **D-061 — line 56 — IMAGERY — Avatar uses `HLProfileAvatar`** which gravatar-fetches. KEEP, this is canonical.

### 6.22 PersonalSettingsScreen (`HealthLog/Screens/PersonalSettings/PersonalSettingsScreen.swift`)

- **D-062 — Two profile screens** — `ProfileScreen` AND `PersonalSettingsScreen` both exist and both render hero + form. PersonalSettingsScreen is presented as a sheet historically; ProfileScreen is the v0.5.4-NF-1 push from the Dashboard-avatar. Operator: "Profil bearbeiten doppelt" likely refers to this duplication. Y6 picks one (ProfileScreen — the push pattern is the operator-loved one) and deletes PersonalSettingsScreen.

### 6.23 MeasurementListScreen + ChartDetailScreen

- **D-063 — `ChartDetailScreen.swift:611` — COLOR — StatBox background `HLColor.surface`** — equivalent to `HLSurface.secondary` in current resolution but should lock to `HLSurface.tertiary` so pills read as recessed wells, not floating mini-cards (operator: "Min/Max/Median + time-range pills dunkelblau, sollen schwarz" — the "schwarz" interpretation = recessed/dark-well treatment).
- **D-064 — `ChartDetailScreen.swift:701-704` — COLOR — Source-pill colors per source** (appleHealth=accent, withings=cyan, manual=accent, import=orange). Convert all four to `HLText.secondary`.
- **D-065 — `ChartDetailScreen.swift:96` — COLOR — `.background(HLColor.background.ignoresSafeArea())`** — should be `HLSurface.primary` for consistency with screens that resolve through `hlScreenBackground()`.
- **D-066 — `MeasurementListScreen.swift:132` — COLOR — `.background(HLColor.background)`** — same fix, use `HLSurface.primary` or `hlScreenBackground()`.
- **D-067 — `MeasurementListScreen.swift` — LAYOUT — Befunde row 2-line "Assistent - Befund + Zwischengespeichert"** — operator-flagged. Verify in BefundeRow code path (need to find which row component renders this). Y7 owns the verification + single-line rewrite.

---

## 7. Implementation wave dependency

Each wave is one feat-branch / one PR.

### Y1 — Accent-picker deprecation + token cleanup

- **Findings closed:** D-005, D-007, D-010, D-011, D-020, D-022 (partial), D-026, D-028..D-036 (partial), D-038, D-039, D-047, D-058, D-064.
- **Files touched:** `DesignSystem/Tokens.swift` (HLTint deprecation), `DesignSystem/HLButton.swift` (drop accent reads), `DesignSystem/HLCard.swift` (no change), every `Screens/**/*.swift` that reads `Color.accentColor` / `.tint` / `HLColor.purple/cyan/pink/orange` (~30 files), `Stores/SettingsStore.swift` (preferredTint deprecated). Add a runtime guard logging if `userBrandTint` is read in DEBUG.
- **Risks:**
  - Existing user preferences for accent persist in UserDefaults — drop silently, no migration UI.
  - Coach Hero gradient removal is a visual shock for any existing user who's seen it — pair with Y3 (Coach redesign) so the surface lands cohesive.
  - `HLChartTints.series` lookup writes are persisted; need to verify no test asserts on the resolved color.
  - Onboarding + LaunchScreen splash KEEP purple — those are brand-anchor surfaces (`HLAccent.primary`). Don't touch Onboarding files.

### Y2 — Sheet pattern unification (Home-Compliance everywhere)

- **Findings closed:** AP-006, AP-007, AP-008, D-001, D-038. Plus sheet-by-sheet review of: HealthScoreDetailSheet, CapturePickerSheet, MoodQuickEntrySheet, AIConsentSheet, AchievementDetailSheet, BenchmarkSourceSheet, MiniCoachSheet, AskCoachSheet, PhotoOfMedSheet.
- **Files touched:** ~10 sheet files in `Screens/`. Each loses its `topBarTrailing` X-button / `Fertig` button / `cancellationAction` Abbrechen.
- **Risks:**
  - Edit-form sheets (Add/EditMedication, MeasureSheet, AddTitrationStep, EditPen) MUST KEEP their cancel/save buttons. Document the exception in the handbook (already done in §4.1).
  - `DeleteAccountScreen` keeps its `Schließen` because of the destructive flow.

### Y3 — Medications screen + MedicationDetailScreen rework

- **Findings closed:** D-018, D-019, D-020 (chrome cleanup that survives), D-021, D-022, D-023, D-024, D-025, D-026, D-027, plus AP-014 verification.
- **Files touched:** `MedicationsScreen.swift`, `ActiveMedicationRow.swift`, `MedicationDetailScreen.swift` (ScheduleSection rewrite, % in-time chip add), `IntakeHistoryRow.swift` (verify pending icon rendering), `MedicationQuickMarkButton.swift` (deletion candidate after D-019).
- **Risks:**
  - Removing per-row quick-mark CHANGES the operator's daily workflow (was 1-tap, becomes 2-tap via detail). Verify operator wants this. The compromise in Home (AnstehendeEinnahmenSheet) gives 1-tap quick-mark from the dashboard, so detail-route on Medikamente tab is the right divider.
  - "% in-time" metric needs a definition (within ±2h of scheduledFor?). Spec must come from operator.
  - Plan rewrite ("Wöchentlich Mittwoch 08:00") needs locale-aware weekday formatting + handles weekday-set sizes 1/2/many.

### Y4 — Insights restructure + MoreScreen reorg

- **Findings closed:** D-009 (Insights coin → inline), D-012 (Correlations → subpage), D-013 + D-014 (PerKindInsightsBlock → tile-grid), D-042 (gear-icon styling), D-043 (LOINC move to Advanced), D-044 (Sign-out/Delete in MoreScreen).
- **Files touched:** `InsightsScreen.swift`, `PerKindInsightsBlock.swift`, new `CorrelationsScreen.swift`, `MoreScreen.swift`, `SettingsAdvancedScreen.swift`, `AskCoachCollapsedCoin.swift` (re-position).
- **Risks:**
  - Tile-grid for per-kind metrics: which metrics get a tile? Operator listed Blutdruck/Gewicht/Ruhepuls/Mood/Mood-Stab/Compliance/Steps/d. Map each to a `MetricKind`; Compliance is its own non-metric tile. Mood-Stab is a derivation, not a stored kind — need a `MoodStabilityKind` (derived).
  - Moving LOINC out of MoreScreen breaks the existing accessibility identifier — update tests.

### Y5 — Settings drift sweep

- **Findings closed:** D-048, D-049, D-050, D-051, D-052, D-053, D-054, D-055..057.
- **Files touched:** `SettingsDevicesScreen.swift`, `SettingsIntegrationsScreen.swift`, `SettingsAdvancedScreen.swift`, `DesignSystem/HLSettingsCard.swift` (potentially bump title to `.hlTitle3`), `DesignSystem/HLSettingsPage.swift`.
- **Risks:**
  - Bumping `HLSettingsCard.title` to `.hlTitle3` cascades across **every** Settings sub-screen — snapshot tests will flag. Walk through each screen, accept the snapshots if visually correct.
  - White-on-white fix needs HLSettingsPage rework or HLSettingsCard surface flip — either route is invasive.

### Y6 — Profile collapse + duplicate purge

- **Findings closed:** D-059, D-060, D-061, D-062, AP-017, AP-019.
- **Files touched:** `ProfileScreen.swift` (hero becomes link), DELETE `PersonalSettings/PersonalSettingsScreen.swift` + reroute all callers (search for `PersonalSettingsScreen()`), `EditProfileScreen.swift` (verify push integration).
- **Risks:**
  - Deleting PersonalSettingsScreen needs verification that no toolbar/sheet/deep-link callsite still references it. `AppRouter.profilePath` may reach for it. Grep + rewire.
  - The Dashboard avatar → ProfileScreen push is the single canonical entry point post-Y6.

### Y7 — Measurements + ChartDetail polish

- **Findings closed:** D-063, D-064, D-065, D-066, D-067, AP-005 verification.
- **Files touched:** `ChartDetailScreen.swift`, `MeasurementListScreen.swift`, the Befunde row component (need to grep — likely `MeasurementRow` in same file or `MeasurementSummaryRow`).
- **Risks:**
  - Recessed-well treatment for StatBox might dim too much in dark mode against `HLSurface.tertiary` — verify on simulator.
  - Befunde row 2-line issue may need a string-shortening pass in `Localizable.xcstrings` too.

### Cross-wave note — Onboarding off-limits

Onboarding files (`WelcomeStep.swift`, `OnboardingFlow.swift`, `ServerAuthStep.swift`, `ServerURLStep.swift`, `ModeSelectionStep.swift`, `NotificationsPermissionStep.swift`) intentionally retain `HLColor.purple` / `HLColor.purpleDeep`. They are brand-anchor surfaces per `HLAccent.primary` doc. Do not touch in Y1–Y7.

---

## Appendix A — Findings index

D-001..D-067 — see §6. AP-001..AP-020 — see §5.

## Appendix B — Reference call-sites (link table)

- Gold standard tile: `HealthLog/Screens/Dashboard/Tiles/HLDashboardTile.swift:84`
- Gold standard card: `HealthLog/DesignSystem/HLCard.swift:18`
- Gold standard sheet: `HealthLog/Screens/Dashboard/AnstehendeEinnahmenSheet.swift:44`
- Gold standard header: `HealthLog/Screens/Dashboard/DashboardHeader.swift:32`
- Gold standard avatar: `HealthLog/DesignSystem/HLProfileAvatar.swift`
- Gold standard button: `HealthLog/DesignSystem/HLButton.swift:78`
- Section-header rhythm: `HealthLog/Screens/Medications/MedicationDetailScreen.swift:373-377` ("VERLAUF" uppercase pattern)

## Appendix C — Verdict guard

Every Y-wave PR review confirms:

1. No raw `HLColor.purple/cyan/pink/orange/purpleDeep` in touched screens (lint rule planned).
2. No new `Color.accentColor` reads.
3. New sheets use the Home-Compliance pattern unless documented exception.
4. Touched buttons share size with their screen siblings.
5. New screen sections use `HLSpace.lg` horizontal padding, `HLSpace.lg` top, `HLSpace.lg` between major surfaces.
6. New cards are `HLCard` (no raw `RoundedRectangle.fill`).
7. New text uses `Font.hl*` semantic tokens (no raw `.system(size:)`).
8. Hierarchy: title ≥ subtitle within a row; headline ≥ body within a card.

This is the bar.
