# UI MANIFEST — HealthLog iOS

**Status:** Binding contract. Last updated 2026-05-22 (v0.5.5+).
**Owner:** HealthLog maintainer.
**Scope:** Every screen rendered inside `AuthenticatedShell`. Onboarding,
LaunchScreen, and Splash are intentionally excluded (those are brand-anchor
surfaces — see `HLAccent.primary`).

This file is the design-system contract every screen MUST follow. If a screen
deviates, it is a defect, not a stylistic choice. Subsequent sessions audit
against this file before shipping any UI change.

## Operator verdict (2026-05-22) — pin

> "Schriften sehr unterschiedlich. Die Medikamentenseite ist komisch. Das
> Dashboard + Insights (BMI-Karten etc.) ist genau richtig — Font + Größe +
> Kachel-Style perfekt. Beibehalten + überall replizieren. Beim Plus-Drücken
> (Capture-Sheet) wirkt der Hintergrund komisch — oben/unten haben
> unterschiedliche Hintergrundfarben + manche Kacheln haben helleren
> Hintergrund. Soll alles monochrom dunkel oder hell wie Dashboard sein."

That verdict is the contract. Below is the implementation.

---

## 1. Gold standards (canonical references)

Both surfaces are off-limits to incidental refactors. Future work copies
their tokens, never the other direction.

### 1.1 Dashboard tile (canonical compact card)

**Reference call-site:** `HealthLog/Screens/Dashboard/Tiles/HLDashboardTile.swift:84-106`.

Layout contract:

| Element            | Token / value                                  | Source line                                  |
|--------------------|------------------------------------------------|----------------------------------------------|
| Outer wrapper      | `HLCard {}` (style: `.standard`)               | `HLDashboardTile.swift:85`                   |
| Card background    | `HLSurface.secondary` (via `HLCard.background`)| `HLCard.swift:39-44`                         |
| Card corner radius | `HLRadius.lg` (18pt)                           | `HLCard.swift:23` + `Tokens.swift:168`       |
| Card padding       | `HLSpace.lg` (16pt — all edges)                | `HLCard.swift:20`                            |
| Inner spacing      | `HLSpace.sm` (8pt vertical between rows)       | `HLDashboardTile.swift:86`                   |
| Header glyph       | `.system(size: 14, weight: .semibold)` on `HLText.secondary` | `HLDashboardTile.swift:117-119`  |
| Header title       | `.hlCaption.weight(.semibold)` on `HLText.secondary` | `HLDashboardTile.swift:121-122`        |
| Primary value      | `.hlMetric(primaryValueSize)` (`@ScaledMetric`, relative to `.title2`, default 28pt) on `HLText.primary` | `HLDashboardTile.swift:134-136` |
| Unit label         | `.hlCaption` on `HLText.secondary`             | `HLDashboardTile.swift:158-159`              |
| Sparkline          | `HLSparkline(values:, tint: HLText.tertiary)`, 36pt height | `HLDashboardTile.swift:279-281`  |
| Empty placeholder  | em-dash, color = `HLText.tertiary`             | `HLDashboardTile.swift:136`                  |

**Why this is gold:** every paint resolves to `HLText.primary/secondary/
tertiary` (Theme-2.0 mono asset) and `HLSurface.secondary` (mono card surface,
white over warm canvas in light / lifted-charcoal in dark). No raw white, no
raw padding ints, no ad-hoc shades. The tile reads as the same calm material
across all eight Dashboard metrics — that's the felt-quality the operator
called out.

### 1.2 Insights elongated card (canonical wide card)

**Reference call-site:** `HealthLog/Screens/Insights/InsightsDigestComponents.swift:20`
+ `:117` (DataQualityCard / classification cards — both adhere identically).

Layout contract:

| Element            | Token / value                                  |
|--------------------|------------------------------------------------|
| Outer wrapper      | `HLCard {}` (style: `.standard`)               |
| Inner spacing      | `HLSpace.sm` (8pt) for stacked rows; `HLSpace.md` for grouped sections |
| Section header     | `.hlFootnote.weight(.semibold)`, `.textCase(.uppercase)`, `tracking(0.5)` on `HLText.secondary` |
| Headline value     | `.hlTitle2` or `.hlMetric(.title)` on `HLText.primary` |
| Body / caption     | `.hlSubhead` or `.hlCaption` on `HLText.secondary` |
| Disclaimer / meta  | `.hlCaption` on `HLText.tertiary`              |

**The elongated card uses the same `HLCard` chrome as the Dashboard tile —
only the inner layout grows vertically.** That's the source of the "looks
consistent" felt-quality: one card primitive, two layouts.

---

## 2. Typography contract

Every surface routes through one of these tokens. **No raw `Font.system(...)`,
no `Font.body`, no `.font(.subheadline)`** at the screen layer — only at the
DesignSystem layer behind a named alias.

| Surface element                                | Required token                       | Required weight   | Color                |
|------------------------------------------------|--------------------------------------|-------------------|----------------------|
| Screen large-title (`navigationTitle`)         | system (Apple-owned via `.navigationTitle`) | (system) | (system, follows tint) |
| Section header (group label, "HEUTE", "AKTIV") | `.hlFootnote`                        | `.semibold` + `.textCase(.uppercase)` + `tracking(0.5)` | `HLText.secondary` |
| Card eyebrow / category label                  | `.hlCaption`                         | `.semibold`       | `HLText.secondary`   |
| Card title / row name                          | `.hlSubhead`                         | `.semibold`       | `HLText.primary`     |
| Card headline (Insights wide card)             | `.hlTitle2` or `.hlMetric(.title)`   | (token-owned)     | `HLText.primary`     |
| Tile value (Dashboard)                         | `.hlMetric(primaryValueSize)` w/ `@ScaledMetric(relativeTo: .title2)` | (token-owned, bold/rounded) | `HLText.primary` |
| Tile unit                                      | `.hlCaption`                         | `.regular`        | `HLText.secondary`   |
| Body copy                                      | `.hlBody`                            | `.regular`        | `HLText.primary`     |
| Secondary/meta copy                            | `.hlSubhead` or `.hlCaption`         | `.regular`        | `HLText.secondary`   |
| Disclaimer / archive-date / tertiary meta      | `.hlCaption`                         | `.regular`        | `HLText.tertiary`    |
| Empty-state placeholder ("—", "noch keine Daten") | inherits per-context             | `.regular`        | `HLText.tertiary`    |

**Rule:** When a screen has a list of rows (Medications, Measurements,
Settings), every row title MUST be `.hlSubhead.weight(.semibold)`. Anything
heavier (`.hlHeadline`) is reserved for cards/sheets. The Medications screen
explicitly downsized from `.hlHeadline` to `.hlSubhead.semibold` in v0.5.5.6
(POLISH-MED) precisely to match this — keep it that way.

---

## 3. Spacing rhythm

Every padding / spacing value MUST resolve to an `HLSpace.*` token. **Raw
integer literals are forbidden at the screen layer.**

| Surface element                                | Required token            |
|------------------------------------------------|---------------------------|
| Card outer padding (handled by `HLCard`)       | `HLSpace.lg` (16pt)       |
| Inside-card row spacing                        | `HLSpace.sm` (8pt)        |
| Inside-card section spacing (multi-section)    | `HLSpace.md` (12pt)       |
| Screen horizontal padding (around scroll content) | `HLSpace.lg` (16pt)    |
| Screen top padding (below nav)                 | `HLSpace.lg` (16pt)       |
| Screen bottom padding (above TabBar)           | `HLSpace.lg` (16pt) — TabView handles its own inset |
| Between top-level sections (HEUTE → AKTIV)     | `HLSpace.lg` (16pt)       |
| Section header → first row inside section      | `HLSpace.sm` (8pt)        |
| Row vertical padding (free-floating list row)  | `HLSpace.xs` (4pt) — slim, or `HLSpace.sm` (8pt) — comfortable |
| Sheet content top inset                        | `HLSpace.md` (12pt)       |
| Sheet content bottom inset                     | `HLSpace.xl` (20pt)       |
| Icon ↔ adjacent text (inside row)              | `HLSpace.md` (12pt) for big icon, `HLSpace.xs` (4pt) for inline glyph |
| Stacked label + sublabel inside row            | `HLSpace.xxs` (2pt)       |

**Rule:** If you reach for `padding(8)`, `padding(.vertical, 12)`,
`spacing: 6`, etc. — STOP. Use the named token. Adding a new size to
`HLSpace` requires a token-layer commit, not a screen-layer one.

---

## 4. Color contract

Theme-2.0 (T2-1..T2-5, 2026-05-16) is the operative ruleset. **The legacy
Dracula-tinted asset aliases (`HLColor.textPrimary/Secondary/Tertiary`,
`HLColor.background`, `HLColor.surface`, `HLColor.surfaceElevated`) are
deprecated for new screen code** — they remain in place only because some
historical surfaces still reference them. New code and the screens this
manifest fixes MUST resolve through the Theme-2.0 namespaces:

| Surface role                                   | Required token                                    |
|------------------------------------------------|---------------------------------------------------|
| Screen canvas (full-bleed background)          | `HLSurface.primary` (via `.hlScreenBackground()`) |
| Card / tile background                         | `HLSurface.secondary` (via `HLCard`)              |
| Recessed well (chip bg, disabled state, sheet) | `HLSurface.tertiary`                              |
| Primary text                                   | `HLText.primary`                                  |
| Secondary text                                 | `HLText.secondary`                                |
| Tertiary text                                  | `HLText.tertiary`                                 |
| Accent / CTA fill                              | `HLAccent.userBrandTint` or `.tint(...)` inheritance |
| Status — success                               | `HLColor.statusOK` (Dracula green)                |
| Status — warning                               | `HLColor.statusWarn` (Dracula orange)             |
| Status — error / adverse                       | `HLColor.statusBad` (Dracula red)                 |
| Separator                                      | `HLColor.separator`                               |

**`.hlScreenBackground()` is the ONLY way a screen sets its canvas color.**
Don't call `.background(HLColor.background)` directly — it skips the
`scrollContentBackground(.hidden)` + `listRowBackground` wipes the modifier
performs.

**Sheet canvases follow the same rule** — `HLSurface.primary` for sheet
content background. The Liquid-Glass tinted-canvas branch
(`HLColor.background.opacity(0.4)`) in `CapturePickerSheet` was an iOS 26
polish that produced visual drift; replaced with `HLSurface.primary` so the
sheet matches the screens beneath it.

**`hlGlassBackground` fallback color updated** — the iOS 18-25 fallback
(formerly `HLColor.surface` — Dracula-tinted) now resolves through
`HLSurface.secondary` at call-sites that want Theme-2.0 parity. Pass the
fallback explicitly: `.hlGlassBackground(in: ..., fallback: HLSurface.secondary)`.

---

## 5. Forbidden patterns (anti-canon)

Any of these is grounds for reviewer rejection without further debate.

1. **Raw colors at screen layer** — `Color.white`, `Color.black`, `Color(.systemGray6)`, `Color(red:0.95, ...)`. Always route through an `HLSurface.*` / `HLText.*` / `HLColor.*` token.
2. **Raw padding / spacing ints** — `padding(12)`, `spacing: 8`, `padding(.horizontal, 16)`. Always use `HLSpace.*`.
3. **Raw `Font.system(...)` or system-style aliases** — `.font(.body)`, `.font(.subheadline)`. Always use `Font.hl*` tokens.
4. **Legacy Dracula text aliases on new code** — `HLColor.textPrimary/textSecondary/textTertiary` are deprecated. Use `HLText.primary/secondary/tertiary`.
5. **Legacy Dracula surface aliases on new code** — `HLColor.background/surface/surfaceElevated/backgroundEleva`. Use `HLSurface.primary/secondary/tertiary`.
6. **Mixing tile background shades in one screen** — every card in one screen renders on the same `HLSurface.secondary`. No "this card is slightly lighter" ad-hoc adjustments.
7. **Sheet canvas ≠ screen canvas under it** — if the user dismisses the sheet and sees a different shade beneath, the sheet shade was wrong. Both resolve to `HLSurface.primary`.
8. **`.hlHeadline` for free-floating list-row title** — that's card-only weight. Use `.hlSubhead.weight(.semibold)` on rows.
9. **`HLBadge` decorative pills for status that has an inline SF Symbol** — the icon carries the signal; the pill duplicates. POLISH-MED (v0.5.5.6) deleted these; don't reintroduce.
10. **Hardcoded UI strings** — every user-visible string lives in `Localizable.xcstrings` (already a project-wide rule; reiterated here so the manifest is self-contained).
11. **Per-screen tab/section opacity tweaks** — `.opacity(0.55)`, `.opacity(0.8)`. Opacity is a token-layer decision (`HLOpacity.*`).
12. **Large title + uppercased section header touching** — leave at least `HLSpace.lg` between them. The large title carries its own breathing room; collapsing it onto a section header reads as broken hierarchy.

---

## 6. Reference call-sites (per rule)

For every contract rule there is at least one current-shipping surface that
demonstrates it correctly. New surfaces audit against these.

| Rule                                       | Reference call-site                                                              |
|--------------------------------------------|----------------------------------------------------------------------------------|
| Dashboard tile gold standard               | `HealthLog/Screens/Dashboard/Tiles/HLDashboardTile.swift:84-106`                 |
| Insights elongated card gold standard      | `HealthLog/Screens/Insights/InsightsDigestComponents.swift:20-50` (BMI card)     |
| `.hlScreenBackground()` canvas             | `HealthLog/Screens/Insights/InsightsScreen.swift:65`                             |
| Section header pattern                     | `HealthLog/Screens/Medications/ActiveMedicationRow.swift:209-214` (post-fix)     |
| Row title `.hlSubhead.semibold`            | `HealthLog/Screens/Medications/ActiveMedicationRow.swift:56-58`                  |
| Inline SF Symbol status (no pill)          | `HealthLog/Screens/Medications/MedicationsScreen.swift:548-565` (IntakeRow icon) |
| `HLCard` with `HLText.*` text tokens       | `HealthLog/Screens/Dashboard/Tiles/HLDashboardTile.swift:117-160`                |
| `HLSpace.*` adherence                      | `HealthLog/Screens/Dashboard/DashboardScreen.swift` (full screen, scan)          |
| `HLSurface.secondary` card backing         | `HealthLog/DesignSystem/HLCard.swift:39-44`                                      |
| Sheet bg = `HLSurface.primary`             | `HealthLog/Screens/Capture/CapturePickerSheet.swift:158-164` (post-fix)          |
| `.tint(...)` for chevron / accent          | `HealthLog/Screens/Medications/ArchivedMedicationsSection.swift:80` (`.foregroundStyle(.tint)`) |

---

## 7. Maintaining this contract

- **When adding a new screen:** copy `HLDashboardTile.swift` as the visual template; you should never write a raw `Color(...)` or `padding(8)` again. If you reach for one, the token is missing — add it to `Tokens.swift` first, then use the named symbol.
- **When auditing an existing screen:** grep for `HLColor.text`, `HLColor.surface`, `HLColor.background`, `padding(\d`, `Font.system`, `\.font(\.`. Each hit is a probable drift. Compare against the table in §4 / §3 / §2.
- **When the operator says "fonts feel different" or "background looks weird":** that's drift against §2 / §4. Open this file, find the rule, fix the call-site, link it in the commit message.
- **When you propose deviating from the contract:** open `docs/decision-log.md` with the rationale + operator sign-off before touching the screen. The contract is binding precisely because it survives across sessions.

---

## 8. Changelog

- **2026-05-22** — Initial manifest. Authored against operator verdict on
  v0.5.5+ Medikamente + Capture-Sheet drift. Dashboard (`HLDashboardTile`)
  + Insights (`InsightsDigestComponents`) cited as gold standards.
  Medikamente surface (`MedicationsScreen`, `IntakeHistoryRow`,
  `ArchivedMedicationsSection`) + Capture-Sheet (`CapturePickerSheet`)
  refactored in the same session to align with this contract.
