import SwiftUI

/// Daylio-style structured mood-tag picker (v0.14). After the user picks one
/// of the 5 moods, this surface lets them tap **context tags grouped by
/// category** — each an **icon above a short label**, multi-select across
/// categories. Fast, low-friction (daily-use), **monochrome** (graphite ink +
/// the one sanctioned `.tint` selection accent — no Daylio rainbow colors).
///
/// **Source of truth:** the server catalog (`GET /api/mood/tags`) via
/// ``MoodTagCatalogStore``; Lucide icons mapped to SF Symbols, label keys
/// resolved against `Localizable.xcstrings`.
///
/// **a11y:** each tile is one combined element with a localized label and a
/// selected/unselected trait + value; the grid honours Dynamic Type (tiles
/// grow with the text) and reduce-motion (selection cross-fades, no spring).
struct MoodTagPicker: View {
    @Environment(MoodTagCatalogStore.self) private var catalogStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The selected structured-tag keys (multi-select across categories).
    @Binding var selectedKeys: Set<String>

    /// Adaptive grid: tiles are ~76 pt min, growing with Dynamic Type. Adaptive
    /// so the column count tracks the available width without a hardcoded count.
    private let columns = [GridItem(.adaptive(minimum: 76, maximum: 120), spacing: HLSpace.sm)]

    var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.lg) {
            // Skip categories with no BINARY tags — a category that holds only
            // RATED factors (the `factors` group) is rendered by the slider
            // section, so an empty toggle grid + bare header would read broken.
            ForEach(catalogStore.catalog.categories.filter { cat in
                cat.tags.contains(where: Self.isVisibleBinary)
            }) { category in
                categorySection(category)
            }
        }
        .task {
            // Idempotent inside the repo TTL — warms the server catalog over
            // the bundled fallback the store seeds with.
            await catalogStore.load()
        }
    }

    private func categorySection(_ category: MoodTagCategoryDTO) -> some View {
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            HStack(spacing: HLSpace.xs) {
                Image(systemName: category.sfSymbol)
                    .font(.hlFootnote.weight(.semibold))
                    .foregroundStyle(HLText.tertiary)
                    .accessibilityHidden(true)
                HLSectionLabel(verbatim: category.localizedLabel)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            LazyVGrid(columns: columns, alignment: .leading, spacing: HLSpace.sm) {
                // v0.14.1 §7 — only BINARY tags render as toggle tiles here.
                // RATED factors (Mood v2) are scored via sliders in a dedicated
                // section (`MoodScreen.ratedFactorsSection`), not as on/off chips.
                ForEach(category.tags.filter(Self.isVisibleBinary)) { tag in
                    MoodTagTile(
                        tag: tag,
                        categoryLabel: category.localizedLabel,
                        selected: selectedKeys.contains(tag.key),
                        reduceMotion: reduceMotion
                    ) {
                        toggle(tag.key)
                    }
                }
            }
        }
    }

    /// A tag renders as a toggle tile iff it is BINARY. v1.13.0 — the interim
    /// client-side hide-sets are RETIRED: the effective server GET already omits
    /// hidden/inactive tags, so a second client-side hide would double-hide. The
    /// only client gate left is RATED (those render as sliders, not toggles).
    nonisolated static func isVisibleBinary(_ tag: MoodTagDTO) -> Bool {
        !tag.isRated
    }

    private func toggle(_ key: String) {
        if selectedKeys.contains(key) {
            selectedKeys.remove(key)
        } else {
            selectedKeys.insert(key)
        }
    }
}

/// A single icon-above-label tag tile. Monochrome: graphite glyph + label;
/// **selected** = filled tinted background + tint ink (per the doctrine,
/// selection is shown by fill/tint state, not a per-category color).
struct MoodTagTile: View {
    let tag: MoodTagDTO
    /// The parent category's localized label ("Sleep") — folded into the
    /// VoiceOver label so the tile reads "Sleep: good" not the bare "good"
    /// (a free-floating tag word has no meaning out of its category context).
    let categoryLabel: String
    let selected: Bool
    let reduceMotion: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: HLSpace.xs) {
                // Fixed-size glyph inside a fixed-height tile slot: the icon is
                // decorative (a11y-hidden) and lives in a `.frame(height: 26)`
                // box, so a Dynamic-Type-scaling glyph would clip the tile.
                // The label below DOES scale (semantic `.hlCaption`), which is
                // the text VoiceOver + Dynamic-Type users read.
                Image(systemName: MoodTagSFSymbol.symbol(forTag: tag))
                    // swiftlint:disable:next dynamic_type_bypass
                    .font(.system(size: 22, weight: .regular))
                    .frame(height: 26)
                    .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(HLText.primary))
                    .accessibilityHidden(true)
                Text(tag.localizedLabel)
                    .font(.hlCaption)
                    .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(HLText.secondary))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 68)
            .padding(.vertical, HLSpace.sm)
            .padding(.horizontal, HLSpace.xs)
            // v0.14.7 B2 — unselected tiles read from the SAME dark ramp as the
            // sheet (`HLSurface.primary` canvas → `HLSurface.secondary` panel →
            // `HLSurface.tertiary` wells). The old `HLColor.surface.opacity(0.5)`
            // was a translucent off-black from a different ramp that read as an
            // "odd off-black mismatch" against the panel; `HLSurface.tertiary`
            // (the same token the note field + slider track already use) makes
            // the whole sheet one cohesive black.
            .background(
                RoundedRectangle(cornerRadius: HLRadius.md, style: .continuous)
                    .fill(selected
                        ? AnyShapeStyle(Color.accentColor.opacity(0.14))
                        : AnyShapeStyle(HLSurface.tertiary))
            )
            .overlay(
                RoundedRectangle(cornerRadius: HLRadius.md, style: .continuous)
                    .stroke(
                        selected ? AnyShapeStyle(.tint) : AnyShapeStyle(HLText.tertiary.opacity(0.18)),
                        lineWidth: selected ? 1.5 : 1
                    )
            )
            .contentShape(Rectangle())
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: selected)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint(Text("mood.tagPicker.tile.hint"))
    }

    /// "Sleep: good" — the category context + the tag, so the standalone tag
    /// word is meaningful. Selection state rides on the `.isSelected` trait
    /// above (VoiceOver appends "selected" automatically).
    private var accessibilityLabel: String {
        String(localized: "\(categoryLabel): \(tag.localizedLabel)")
    }
}

/// v0.14.5 §R1–R3 — one Mood v2 **rated factor** as a **monochrome slider**.
///
/// **Continuous feel, fixed polarity (R2):** the slider always reads RIGHT =
/// good, LEFT = bad. The wire `rating` (raw `scaleMin…scaleMax`) is *derived*
/// from the thumb position honouring the catalog `inverse` flag:
///   - non-inverse (higher raw = better, e.g. work / sleep_quality) → RIGHT
///     maps to the HIGH raw rating.
///   - inverse (higher raw = worse, e.g. sadness / stress / conflict) → RIGHT
///     (good) maps to the LOW raw rating.
/// Pure mapping in ``MoodRatedFactorScale`` (unit-tested for both polarities,
/// clamp, and the `scaleMax == 2` two-state case).
///
/// **Untouched (R2):** `rating == nil` ⇒ the thumb sits centred + the track is
/// dimmed, and the factor is omitted on save. The first drag/tap rates it.
///
/// **Monochrome-dark (R3):** graphite/ink track + ink thumb, HLText hierarchy.
/// No `.tint` / `Color.accentColor` (those resolve to the user-picked tint =
/// the blue "Fremdkörper"); selection is shown by ink fill + active track.
///
/// **scaleMax == 2 (R2):** rendered as a clean two-position slider (snaps to
/// the two endpoints) with unmistakable good/bad end labels.
struct MoodRatedFactorRow: View {
    let factor: MoodTagDTO
    /// `nil` until the user scores it (so an untouched factor is never sent).
    @Binding var rating: Int?
    var reduceMotion = false

    /// v0.14.6 M3 — per-drag direction lock. `nil` before the first significant
    /// move; set once to whether the gesture is predominantly HORIZONTAL. A
    /// vertical gesture (page scroll started on the thumb) is ignored so the
    /// slider never jumps when the user is actually scrolling the sheet. Reset
    /// on gesture end.
    @State private var dragIsHorizontal: Bool?

    private var model: MoodRatedFactorScale {
        MoodRatedFactorScale(factor: factor)
    }

    /// 0 = far-left (bad), 1 = far-right (good). Untouched parks the thumb in
    /// the visual middle without marking the factor rated.
    private var position: Double {
        guard let rating else { return 0.5 }
        return model.position(forRating: rating)
    }

    private var isTwoState: Bool {
        factor.scaleMax - factor.scaleMin == 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.xs) {
            HStack(spacing: HLSpace.xs) {
                Image(systemName: MoodTagSFSymbol.symbol(forTag: factor))
                    // swiftlint:disable:next dynamic_type_bypass
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(rating == nil ? HLText.tertiary : HLText.secondary)
                    .accessibilityHidden(true)
                Text(factor.localizedLabel)
                    .font(.hlSubhead)
                    .foregroundStyle(rating == nil ? HLText.secondary : HLText.primary)
                Spacer(minLength: 0)
                if rating == nil {
                    Text("mood.ratedFactor.notRated")
                        .font(.hlCaption2)
                        .foregroundStyle(HLText.tertiary)
                }
            }

            slider

            HStack {
                Text("mood.ratedFactor.bad")
                    .font(.hlCaption2)
                    .foregroundStyle(HLText.tertiary)
                Spacer(minLength: 0)
                Text("mood.ratedFactor.good")
                    .font(.hlCaption2)
                    .foregroundStyle(HLText.tertiary)
            }
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(factor.localizedLabel))
        .accessibilityValue(Text(a11yValue))
        .accessibilityAdjustableAction { direction in
            adjust(direction)
        }
    }

    private var slider: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let thumb: CGFloat = 26
            let usable = max(width - thumb, 1)
            let touched = rating != nil
            let x = thumb / 2 + CGFloat(position) * usable

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(HLSurface.tertiary)
                    .frame(height: 6)
                // Active fill from the centre toward the thumb, only once rated.
                if touched {
                    Capsule()
                        .fill(HLText.primary.opacity(0.85))
                        .frame(width: max(x - thumb / 2, 0), height: 6)
                }
                Circle()
                    .fill(touched ? HLText.primary : HLSurface.secondary)
                    .overlay(
                        Circle().stroke(
                            touched ? HLText.primary : HLText.tertiary.opacity(0.4),
                            lineWidth: 1
                        )
                    )
                    .frame(width: thumb, height: thumb)
                    .opacity(touched ? 1 : 0.55)
                    .offset(x: x - thumb / 2)
                    .shadow(color: .black.opacity(touched ? 0.18 : 0), radius: 2, y: 1)
            }
            // A2/M3 — the visual track/thumb stay 26 pt but the HIT area is 44 pt
            // (HIG minimum), so the thumb is comfortable to grab and the
            // horizontal scrub is easier to start than a vertical scroll — which
            // also shrinks the residual vertical-scroll dead-zone over the band.
            .frame(height: 44)
            .contentShape(Rectangle())
            // M3 — a deliberate HORIZONTAL drag scrubs the value; a tap sets it
            // at the touch point. `minimumDistance: 8` + the horizontal lock let
            // a vertical page-scroll that happens to start on the thumb pass
            // through to the ScrollView instead of yanking the slider fully to
            // one end (the operator's "springt nach rechts beim Scrollen").
            .gesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { value in
                        if dragIsHorizontal == nil {
                            dragIsHorizontal = abs(value.translation.width) >= abs(value.translation.height)
                        }
                        guard dragIsHorizontal == true else { return }
                        let p = Double((value.location.x - thumb / 2) / usable)
                        commit(position: min(max(p, 0), 1))
                    }
                    .onEnded { _ in dragIsHorizontal = nil }
            )
            .simultaneousGesture(
                SpatialTapGesture()
                    .onEnded { value in
                        let p = Double((value.location.x - thumb / 2) / usable)
                        commit(position: min(max(p, 0), 1))
                    }
            )
            // M3 — premium detent feel: a subtle selection tick each time the
            // discrete rating changes (and the two-state snap), not a continuous
            // buzz. Untouched→nil never fires (trigger only changes on a value).
            .sensoryFeedback(.selection, trigger: rating)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: rating)
        }
        .frame(height: 44)
    }

    /// Map a 0…1 thumb position to a clamped raw rating (two-state snaps to the
    /// nearest endpoint) and store it.
    private func commit(position p: Double) {
        rating = model.rating(forPosition: p, twoState: isTwoState)
    }

    private func adjust(_ direction: AccessibilityAdjustmentDirection) {
        let current = rating ?? model.rating(forPosition: 0.5, twoState: isTwoState)
        let delta = direction == .increment ? 1 : -1
        // Increment always means "better" → move toward the good (high
        // position) end; honour inverse by mapping through position.
        let newPos = min(max(model.position(forRating: current) + Double(delta) / Double(max(factor.scaleMax - factor.scaleMin, 1)), 0), 1)
        commit(position: newPos)
    }

    private var a11yValue: String {
        guard rating != nil else { return String(localized: "mood.ratedFactor.notRated") }
        // Position-based, so VoiceOver always reads good/bad, not raw polarity.
        let pct = Int((position * 100).rounded())
        return HLNumberFormat.percent(pct)
    }
}

/// Pure polarity/scale math for a rated factor — split out so R2 mapping is
/// unit-testable without a View. Position is always 0 (LEFT/bad) … 1
/// (RIGHT/good); the raw `rating` we POST is derived honouring `inverse`.
struct MoodRatedFactorScale: Equatable {
    let scaleMin: Int
    let scaleMax: Int
    let inverse: Bool

    init(scaleMin: Int, scaleMax: Int, inverse: Bool) {
        self.scaleMin = scaleMin
        self.scaleMax = max(scaleMax, scaleMin)
        self.inverse = inverse
    }

    init(factor: MoodTagDTO) {
        self.init(scaleMin: factor.scaleMin, scaleMax: factor.scaleMax, inverse: factor.inverse)
    }

    private var span: Int {
        scaleMax - scaleMin
    }

    /// 0…1 position → clamped raw rating. `twoState` snaps to the two endpoints.
    /// RIGHT (p→1) = good: non-inverse → high raw; inverse → low raw.
    func rating(forPosition rawP: Double, twoState: Bool) -> Int {
        let p = min(max(rawP, 0), 1)
        if span == 0 { return scaleMin }
        let goodness = twoState ? (p >= 0.5 ? 1.0 : 0.0) : p
        // goodness 1 = best. Non-inverse best = scaleMax; inverse best = scaleMin.
        let raw: Double = inverse
            ? Double(scaleMax) - goodness * Double(span)
            : Double(scaleMin) + goodness * Double(span)
        return min(max(Int(raw.rounded()), scaleMin), scaleMax)
    }

    /// Inverse of `rating(forPosition:)` — raw rating → 0…1 good-ward position,
    /// for parking the thumb at a stored value.
    func position(forRating rating: Int) -> Double {
        guard span > 0 else { return 0.5 }
        let clamped = min(max(rating, scaleMin), scaleMax)
        let goodness = inverse
            ? Double(scaleMax - clamped) / Double(span)
            : Double(clamped - scaleMin) / Double(span)
        return min(max(goodness, 0), 1)
    }
}

enum MoodFreeTextTagRules {
    static let maximumCount = 20
    static let maximumLength = 50

    enum InsertResult: Equatable {
        case inserted
        case empty
        case duplicate
        case tooLong
        case tooMany
    }

    @discardableResult
    static func insert(_ raw: String, into tags: inout [String]) -> InsertResult {
        let candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return .empty }
        guard candidate.count <= maximumLength else { return .tooLong }
        guard !tags.contains(where: {
            $0.caseInsensitiveCompare(candidate) == .orderedSame
        }) else { return .duplicate }
        guard tags.count < maximumCount else { return .tooMany }
        tags.append(candidate)
        return .inserted
    }
}

/// Shared manual free-text tag field for capture and edit. It writes the
/// existing `[String]` wire axis and shares the same accepted-chip collection
/// as on-device suggestions.
struct MoodFreeTextTagInput: View {
    @Binding var tags: [String]

    @State private var input = ""
    @State private var result: MoodFreeTextTagRules.InsertResult?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            HStack(spacing: HLSpace.sm) {
                TextField("mood.tags.free.placeholder", text: $input)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .submitLabel(.done)
                    .onSubmit(add)
                    .onChange(of: input) { _, _ in result = nil }
                    .accessibilityIdentifier("mood.tags.free.input")
                Button(action: add) {
                    Image(systemName: "plus.circle.fill")
                        .font(.hlIcon(HLIconSize.rowAction))
                }
                .buttonStyle(.plain)
                .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel(Text("mood.tags.free.add"))
            }
            .padding(HLSpace.md)
            .background(HLSurface.tertiary)
            .clipShape(RoundedRectangle(cornerRadius: HLRadius.sm, style: .continuous))

            HStack {
                if let message {
                    Text(message)
                        .foregroundStyle(HLColor.statusBad)
                }
                Spacer()
                Text("\(tags.count)/\(MoodFreeTextTagRules.maximumCount)")
            }
            .font(.hlCaption)
            .foregroundStyle(HLText.tertiary)

            if !tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: HLSpace.sm) {
                        ForEach(tags, id: \.self) { tag in
                            TagChip(label: tag, selected: true) {
                                tags.removeAll { $0 == tag }
                            }
                        }
                    }
                    .padding(.vertical, HLSpace.xxs)
                }
            }
        }
    }

    private var message: LocalizedStringKey? {
        switch result {
        case .duplicate:
            "mood.tags.free.duplicate"
        case .tooLong:
            "mood.tags.free.tooLong"
        case .tooMany:
            "mood.tags.free.tooMany"
        case .inserted, .empty, .none:
            nil
        }
    }

    private func add() {
        var updated = tags
        let insertion = MoodFreeTextTagRules.insert(input, into: &updated)
        result = insertion
        if insertion == .inserted {
            tags = updated
            input = ""
        }
    }
}
