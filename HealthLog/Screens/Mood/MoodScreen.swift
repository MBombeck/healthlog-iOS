import SwiftUI

/// Mood logging + visualization.
///
/// **v0.6.1.15 Y10 redesign:** rebuilt around the operator's reference
/// layout — centered "Wie geht's dir?" question, a date/time line
/// beneath, and the 5-icon row at center. Icons come from the
/// operator-provided `Mood1...Mood5` imagesets (Lausig / Schlecht /
/// Ok / Gut / Super gut). Multiple entries per day **stack** rather
/// than overwrite — every tap records a new entry against the
/// currently selected timestamp. The date line is tappable: switch
/// to any of the trailing 14 days to back-log a forgotten entry.
///
/// **v0.6.1.19 Y10.5 follow-up:** the screen is now presented as a
/// one-shot quick-entry sheet from Erfassen → Stimmung. Tap a face
/// → `store.log` writes → short delay for the .success haptic and
/// scale-bump confirmation → sheet auto-dismisses. The Letzte
/// Einträge + Verlauf surfaces dropped off this view entirely;
/// re-surfacing them via a Verlauf entry point lives outside Y10.5.
/// Horizontal icon order is best-on-the-left so the natural
/// reading rhythm reads "I'd rather be over here". Tags + Notes
/// still live in the Edit-entry sheet for retrospective annotation.
struct MoodScreen: View {
    @Environment(MoodStore.self) private var store
    /// v0.14 — structured mood-tag catalog (for ordering the selected keys).
    @Environment(MoodTagCatalogStore.self) private var tagCatalog
    @Environment(\.dismiss) private var dismiss
    /// QoL-A2 (Felt-craft #5) — gate the mood-tap scale bounce on reduce-motion.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedDate: Date = .now
    @State private var showDatePicker = false
    @State private var lastTappedScore: Int?
    @State private var tapCount: Int = 0
    /// Bumped on every face tap (before the network write) so the light
    /// impact plays the instant the user commits — independent of the
    /// `.success` cue (`tapCount`) that only fires on a confirmed save.
    @State private var tapImpactCount: Int = 0

    // MARK: - MD1 inline annotate (v0.11 W26)

    /// The just-logged entry awaiting optional annotation. Non-nil reveals
    /// the brief annotate panel (note field + on-device tag-suggest chips +
    /// "Fertig"). `nil` = no panel (fast path / pre-log).
    @State private var annotatingEntry: MoodEntry?
    /// Free-text note the user is typing in the annotate panel.
    @State private var annotateNote: String = ""
    /// Manual free-text tags and accepted on-device suggestions share the same
    /// bounded `[String]` wire collection.
    @State private var annotateTags: [String] = []
    /// v0.14 — structured mood-tag keys picked from the Daylio-style catalog
    /// grid (multi-select across categories). Sent as `tagKeys` on save.
    @State private var annotateTagKeys: Set<String> = []
    /// On-device suggestions surfaced from the note text.
    @State private var annotateSuggestions: [MoodTagSuggestion] = []
    @State private var isSuggesting = false
    /// v0.14.1 §7 — Mood v2 rated factors. `factorKey → rating`. A factor the
    /// user never touched is absent (no "0" rating) and is simply not sent.
    @State private var annotateRatings: [String: Int] = [:]
    @FocusState private var annotateNoteFocused: Bool
    /// v0.14.8 — host-sheet detent, driven programmatically. Pre-log the sheet
    /// sits compact (`.medium`) over just the hero + 5 faces; the moment a mood
    /// is logged (`annotatingEntry != nil`) it grows to a tall detent so the
    /// whole annotate panel — sliders + tag grid + tag-management link + note +
    /// "Fertig" — is visible WITHOUT internal scrolling. The growth animates
    /// (reduce-motion gated) so the surface "opens wide".
    @State private var sheetDetent: PresentationDetent = .medium

    /// The tall detent the sheet grows to once a mood is logged. ~92 % of the
    /// device height — enough for the full annotate panel on an iPhone without
    /// the wasted top void of a hard `.large`, and it leaves the date/hero just
    /// peeking so the surface still reads as the mood-capture sheet.
    private static let annotateDetent: PresentationDetent = .fraction(0.92)

    private static let dateHeaderFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = .autoupdatingCurrent
        f.setLocalizedDateFormatFromTemplate("EEEEdMMMMHHmm")
        return f
    }()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: HLSpace.xl) {
                    pickerHero
                }
                .padding(.horizontal, HLSpace.lg)
                .padding(.top, HLSpace.lg)
                .padding(.bottom, HLSpace.lg)
            }
            .hlScreenBackground()
            // QoL-A2 (Glass M1) — iOS-26 soft scroll-edge to match the
            // canonical ScrollView-root pattern across screens. No-op on
            // iOS 18-25 (and where the nav bar is hidden).
            .hlScrollEdgeSoft()
            // v0.6.1.19 Y10.5 (j): drop the "Stimmung" navigation
            // title — the centered "Wie geht's dir?" hero is the
            // primary affordance and the screen is now quick-entry
            // only (presented from Erfassen → Stimmung). A redundant
            // title-bar competes with the hero for top real estate.
            .toolbar(.hidden, for: .navigationBar)
            .task {
                await store.revalidateIfStale()
            }
            .hlErrorBannerOverlay(error: store.error) {
                Task { await store.load() }
            }
            .sensoryFeedback(.impact(weight: .light), trigger: tapImpactCount)
            .sensoryFeedback(.success, trigger: tapCount)
            .sheet(isPresented: $showDatePicker) {
                datePickerSheet
            }
        }
        // v0.14.8 — own the host-sheet detent so the screen can grow itself the
        // moment a mood is logged. Pre-log: compact `.medium` over the hero +
        // faces. Post-log: the tall `annotateDetent` so the whole annotate panel
        // fits WITHOUT internal scrolling. Two detents (selection-driven) instead
        // of the former single non-draggable `.compact`, so the grow animates
        // and the user can still nudge it back down. Inner `presentationDetents`
        // wins over the call-site default.
        .presentationDetents([.medium, Self.annotateDetent], selection: $sheetDetent)
        .presentationDragIndicator(.visible)
        .onChange(of: annotatingEntry?.id) { _, newValue in
            // Grow on first log; never auto-shrink mid-annotation (the user may
            // drag down themselves). Reduce-motion gates the grow animation.
            guard newValue != nil else { return }
            withAnimation(reduceMotion ? nil : HLMotion.spring) {
                sheetDetent = Self.annotateDetent
            }
        }
        // v0.14.6 M1 — the mood-logging surface is always DARK: a black/graphite
        // background with dark tiles + dark sliders, cohesive with the v0.14.5
        // monochrome-dark rated sliders (no light/white look). Forcing the
        // environment colorScheme resolves every HLText/HLSurface/HLColor token
        // and the tag tiles to their dark values; `preferredColorScheme` carries
        // the dark treatment to the presented sheet chrome too.
        .environment(\.colorScheme, .dark)
        .preferredColorScheme(.dark)
    }

    // MARK: - Hero picker

    private var pickerHero: some View {
        VStack(spacing: HLSpace.lg) {
            Text("How are you?")
                .font(.hlLargeTitle)
                .foregroundStyle(HLText.primary)
                .frame(maxWidth: .infinity, alignment: .center)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)

            Button {
                showDatePicker = true
            } label: {
                HStack(spacing: HLSpace.sm) {
                    Image(systemName: "calendar")
                        .font(.hlIcon(HLIconSize.rowAction, weight: .regular))
                        .foregroundStyle(HLText.tertiary)
                    Text(Self.dateHeaderFormatter.string(from: selectedDate))
                        .font(.hlSubhead)
                        .foregroundStyle(HLText.secondary)
                        .underline(color: HLText.tertiary.opacity(0.4))
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Pick date"))
            .accessibilityValue(Text(Self.dateHeaderFormatter.string(from: selectedDate)))

            iconRow
                .padding(.top, HLSpace.sm)

            if annotatingEntry != nil {
                annotatePanel
                    .padding(.top, HLSpace.md)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : HLMotion.spring, value: annotatingEntry?.id)
    }

    // MARK: - MD1 annotate panel (v0.11 W26)

    private var annotatePanel: some View {
        VStack(alignment: .leading, spacing: HLSpace.md) {
            // Every server-visible rated factor comes first, before the binary
            // tag grid. The catalog owns both membership and order.
            ratedFactorsSection

            // v0.14 — Daylio-style structured tag grid (context after the
            // sliders). v0.14.1 §7: the panel STAYS OPEN while the user selects
            // tags / rates factors / types a note. The old grace-window
            // auto-dismiss is gone — only explicit "Fertig" (`commitAnnotation`)
            // or a swipe-down of the host sheet closes it.
            MoodTagPicker(selectedKeys: $annotateTagKeys)

            // v1.13.0 — lightweight entry into the custom-tag management screen
            // (create / edit / hide tags). On-doctrine: a quiet text link, not a
            // prominent button, so it never competes with the capture flow.
            NavigationLink {
                MoodTagManagementScreen()
            } label: {
                HStack(spacing: HLSpace.xs) {
                    Image(systemName: "slider.horizontal.3")
                        .imageScale(.small)
                    Text("mood.tags.manage.entry")
                        .font(.hlSubhead)
                }
                .foregroundStyle(HLText.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("mood.annotate.manageTags")

            // Note field with the on-device tag-suggest folded INLINE on the
            // same row (v0.14.8): a quiet trailing sparkle button instead of a
            // separate stacked suggest panel below, reclaiming the vertical
            // space the old block ate. Same `runAnnotateSuggest()` behaviour +
            // disabled / progress / fallback states — just relocated.
            noteRow

            MoodFreeTextTagInput(tags: $annotateTags)

            // Suggested tags surfaced from the note (only after a run).
            if store.supportsTagSuggestions, !annotateSuggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: HLSpace.sm) {
                        ForEach(annotateSuggestions) { suggestion in
                            TagChip(label: suggestion.label, selected: false) {
                                acceptSuggestion(suggestion)
                            }
                        }
                    }
                }
            }

            HLButton(String(localized: "mood.annotate.done"), variant: .restrained) {
                Task { await commitAnnotation() }
            }
            .accessibilityIdentifier("mood.annotate.done")
        }
        .padding(HLSpace.md)
        // v0.14.1 §7 — the tag submenu read noticeably lighter than the rest of
        // the app (`HLColor.surface.opacity(0.5)` is a translucent well). Use the
        // canonical card-backing surface (`HLSurface.secondary`) the other sheets
        // / cards use so the panel matches the standard background.
        .background(
            RoundedRectangle(cornerRadius: HLRadius.md, style: .continuous)
                .fill(HLSurface.secondary)
        )
    }

    /// Note text field with the on-device tag-suggest affordance folded in on
    /// the SAME row — a quiet trailing sparkle button (spinner while running),
    /// disabled until there's note text, hidden entirely when the device can't
    /// suggest. This replaces the former separate stacked "Tags vorschlagen"
    /// panel and reclaims its vertical space.
    private var noteRow: some View {
        HStack(alignment: .center, spacing: HLSpace.sm) {
            TextField(String(localized: "mood.annotate.note.placeholder"), text: $annotateNote, axis: .vertical)
                .lineLimit(1 ... 3)
                .focused($annotateNoteFocused)
                .textFieldStyle(.plain)
                .accessibilityIdentifier("mood.annotate.note")

            if store.supportsTagSuggestions {
                Button {
                    Task { await runAnnotateSuggest() }
                } label: {
                    Group {
                        if isSuggesting {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "sparkles")
                                .font(.hlIcon(HLIconSize.rowAction))
                        }
                    }
                    .foregroundStyle(.tint)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isSuggesting || annotateNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel(Text("mood.annotate.suggest"))
                .accessibilityHint(Text("mood.annotate.suggest.hint"))
            }
        }
        .padding(HLSpace.md)
        .background(HLSurface.tertiary)
        .clipShape(RoundedRectangle(cornerRadius: HLRadius.sm, style: .continuous))
    }

    private var iconRow: some View {
        HStack(alignment: .top, spacing: HLSpace.md) {
            // v0.6.1.19 Y10.5 (g): horizontal order is best-on-the-left,
            // worst-on-the-right per operator brief. Score 5 (Super)
            // first, score 1 (Lausig) last — matching the natural
            // left-to-right reading rhythm "I'd rather be over here".
            ForEach(Array((1 ... 5).reversed()), id: \.self) { value in
                moodIconButton(value)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func moodIconButton(_ value: Int) -> some View {
        Button {
            Task { await record(score: value) }
        } label: {
            VStack(spacing: HLSpace.xs) {
                Image(MoodCopy.iconName(for: value))
                    .resizable()
                    .scaledToFit()
                    .frame(width: 56, height: 56)
                    .scaleEffect(lastTappedScore == value ? 1.08 : 1.0)
                    .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.6), value: lastTappedScore)
                    .accessibilityHidden(true)
                Text(MoodCopy.scoreLabel(value))
                    .font(.hlCaption)
                    .foregroundStyle(HLText.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(MoodCopy.accessibilityLabel(for: value)))
        .accessibilityValue(Text("\(value) of 5"))
    }

    private func record(score: Int) async {
        // Declarative light impact via `.sensoryFeedback` — fires the
        // moment the tap commits (reduce-motion / accessibility aware).
        tapImpactCount += 1
        lastTappedScore = score
        // v0.11 W26 — undo-aware quick log: the store enqueues a `Rückgängig`
        // toast (hosted by AuthenticatedShell) so a mis-tapped face is
        // reversible even after the sheet auto-dismisses.
        let saved = await store.logUndoable(score: score, recordedAt: selectedDate)
        if let saved {
            tapCount += 1
            // MD1 (v0.11 W26): instead of a hard auto-dismiss, reveal the
            // optional annotate panel (rated sliders + tag grid + note + on-device
            // tag-suggest) so the daily flow can reach the context that is the
            // value in a mood tracker. v0.14.8 — the panel now also GROWS the host
            // sheet to a tall detent (via `onChange(of: annotatingEntry?.id)`) so
            // everything is visible without internal scrolling. The panel STAYS
            // OPEN until explicit "Fertig" (`commitAnnotation`) or a swipe-down of
            // the host sheet — there is no grace-window auto-dismiss.
            annotatingEntry = saved
            annotateNote = saved.note ?? ""
            annotateTags = []
            annotateTagKeys = Set(saved.tagKeys)
            // v0.14.7 — pre-fill the rated sliders from the entry's decoded
            // rated factors so re-opening the panel on an entry that already
            // carries ratings shows the saved value (not "nicht bewertet"),
            // and a re-save doesn't silently drop them. Fresh logs decode `[]`,
            // so this is a no-op on the quick-log path.
            annotateRatings = Dictionary(
                saved.ratedFactors.map { ($0.key, $0.rating) },
                uniquingKeysWith: { first, _ in first }
            )
            annotateSuggestions = []
        }
    }

    /// Commit the optional annotation onto the just-logged entry, then
    /// dismiss. Skips the server round-trip entirely when nothing was added
    /// (fast path stays a no-op write).
    private func commitAnnotation() async {
        guard let entry = annotatingEntry else { dismiss()
            return
        }
        let trimmedNote = annotateNote.trimmingCharacters(in: .whitespacesAndNewlines)
        let tagKeys = catalogOrderedSelection()
        // v0.14.1 §7 — Mood v2 rated factors. Only factors the user actually
        // touched are sent (omit = no rating); clamp client-side to the catalog
        // scale so the server never 422s on out-of-range (contract §3).
        let factors = ratedFactorsPayload()
        if !trimmedNote.isEmpty || !annotateTags.isEmpty || !tagKeys.isEmpty || !factors.isEmpty {
            _ = await store.update(
                entry,
                score: entry.score,
                tags: annotateTags,
                tagKeys: tagKeys,
                ratedFactors: factors,
                recordedAt: entry.recordedAt,
                note: trimmedNote.isEmpty ? nil : trimmedNote
            )
        }
        annotatingEntry = nil
        dismiss()
    }

    /// Project the selected tag-key set into a stable, catalog-ordered array.
    private func catalogOrderedSelection() -> [String] {
        tagCatalog.catalog.orderedKeys(from: annotateTagKeys)
    }

    // MARK: - Mood v2 rated factors (v0.14.1 §7)

    /// Every visible RATED factor in the catalog, in catalog order. The server
    /// taxonomy is authoritative; iOS applies no fixed factor allow-list.
    private var ratedFactors: [MoodTagDTO] {
        tagCatalog.catalog.categories.flatMap { $0.tags.filter(MoodTagCatalog.isVisibleRated) }
    }

    /// Slider section for the Mood v2 rated factors — hidden when the catalog
    /// ships none (pre-v2 server renders exactly as before).
    @ViewBuilder
    private var ratedFactorsSection: some View {
        let factors = ratedFactors
        if !factors.isEmpty {
            VStack(alignment: .leading, spacing: HLSpace.md) {
                HStack(spacing: HLSpace.xs) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.hlFootnote.weight(.semibold))
                        .foregroundStyle(HLText.tertiary)
                        .accessibilityHidden(true)
                    HLSectionLabel("mood.ratedFactors.title")
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                // R4 de-nest: sliders render directly here (no wrapping card /
                // 3rd background) — only this header + the rows, calmer chrome.
                VStack(alignment: .leading, spacing: HLSpace.lg) {
                    ForEach(factors) { factor in
                        MoodRatedFactorRow(factor: factor, rating: Binding(
                            get: { annotateRatings[factor.key] },
                            set: { annotateRatings[factor.key] = $0 }
                        ), reduceMotion: reduceMotion)
                    }
                }
            }
        }
    }

    /// Touched ratings → wire payload, clamped to each factor's own scale (so
    /// the server never 422s). Untouched factors are omitted (no "0" rating).
    private func ratedFactorsPayload() -> [RatedFactorInput] {
        ratedFactors.compactMap { factor in
            guard let raw = annotateRatings[factor.key] else { return nil }
            return RatedFactorInput(key: factor.key, rating: min(max(raw, factor.scaleMin), factor.scaleMax))
        }
    }

    private func runAnnotateSuggest() async {
        isSuggesting = true
        defer { isSuggesting = false }
        let outcome = await store.suggestTags(forNote: annotateNote, existingTags: annotateTags)
        annotateSuggestions = outcome?.suggestions ?? []
    }

    private func acceptSuggestion(_ suggestion: MoodTagSuggestion) {
        var updated = annotateTags
        _ = MoodFreeTextTagRules.insert(suggestion.label, into: &updated)
        annotateTags = updated
        annotateSuggestions.removeAll { $0.id == suggestion.id }
    }

    // MARK: - Date picker sheet (back-log up to 14 days)

    private var datePickerSheet: some View {
        NavigationStack {
            VStack {
                DatePicker(
                    String(localized: "Date & time"),
                    selection: $selectedDate,
                    in: Self.allowedDateRange,
                    displayedComponents: [.date, .hourAndMinute]
                )
                .datePickerStyle(.graphical)
                .padding()
                Spacer()
            }
            .navigationTitle(Text("Backdate entry"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "Done")) { showDatePicker = false }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button(String(localized: "Today")) {
                        selectedDate = .now
                    }
                }
            }
        }
        .hlSheetPresentation(.standard)
    }

    /// Back-log window — operator can pick any of the trailing 14 days
    /// plus today. Earlier than that and the cadence breaks down (mood
    /// is a "felt now" check-in, not a journal entry).
    private static var allowedDateRange: ClosedRange<Date> {
        let cal = Calendar.current
        let now = Date.now
        let start = cal.date(byAdding: .day, value: -14, to: now) ?? now
        return start ... now
    }
}

// MARK: - Canonical mood-copy

/// Single source of truth für Score → Display-Label. Mirror der
/// Server-Enum-Reihenfolge. The labels mirror the operator's icon-pack
/// filenames (Lausig / Schlecht / Ok / Gut / Super gut).
enum MoodCopy {
    static func scoreLabel(_ score: Int) -> String {
        switch max(1, min(5, score)) {
        case 1: String(localized: "Awful")
        case 2: String(localized: "Bad")
        case 3: String(localized: "mood.score.ok")
        case 4: String(localized: "Good")
        default: String(localized: "Great")
        }
    }

    /// Canonical Score → Mood-Icon-Asset-Name. Single source of truth für die
    /// fünf Stimmungs-Glyphen (PNG-Pack `Mood1…Mood5` in `Assets.xcassets/Mood`).
    /// Jede Entry-/Picker-Surface (`MoodScreen.iconRow`, `MoodEntryRow`,
    /// `EditMoodSheet`) rendert `Image(MoodCopy.iconName(for:))` — keine
    /// Unicode-Emojis mehr. Out-of-range klemmt auf die Skalen-Endwerte.
    static func iconName(for score: Int) -> String {
        "Mood\(max(1, min(5, score)))"
    }

    /// VoiceOver label per score — kept distinct from `scoreLabel` so
    /// the screen reader announces the scale clearly.
    static func accessibilityLabel(for score: Int) -> String {
        switch max(1, min(5, score)) {
        case 1: String(localized: "Very bad")
        case 2: String(localized: "Bad")
        case 3: String(localized: "Neutral")
        case 4: String(localized: "Good")
        default: String(localized: "Very good")
        }
    }
}

// MARK: - Mood entry row

struct MoodEntryRow: View {
    let entry: MoodEntry
    /// v0.14 — resolve structured tag-keys to icon chips for read-back so the
    /// logging round-trips visibly. `nil`-safe: an env-less preview falls back
    /// to the bundled catalog the store seeds with.
    @Environment(MoodTagCatalogStore.self) private var tagCatalog

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.dateTimeStyle = .named
        f.unitsStyle = .abbreviated
        return f
    }()

    private var displayedTags: [String] {
        entry.tags.filter { !$0.hasPrefix("note:") }
    }

    /// Read-back chips for the structured tag-keys — icon + resolved label per
    /// known catalog key. Unknown keys (deactivated server-side) degrade to a
    /// neutral tag glyph + the raw key so nothing silently vanishes.
    private var structuredTagChips: [MoodReadbackChip] {
        entry.tagKeys.map { key in
            let label = tagCatalog.label(forTagKey: key) ?? MoodTagCatalogL10n.resolve(key)
            let symbol = tagCatalog.catalog.categories
                .flatMap(\.tags)
                .first { $0.key == key }
                .map { MoodTagSFSymbol.symbol(forTag: $0) } ?? "tag"
            return MoodReadbackChip(key: key, label: label, symbol: symbol)
        }
    }

    /// Read-back chips for the RATED factors — each resolved to a labelled value
    /// ("Arbeit: gut"). The factor's human label + inverse flag come from the
    /// catalog (server `ratedFactors` carries only `key` + raw `rating`). An
    /// unknown key (factor retired server-side) degrades to a humanized key + a
    /// neutral glyph rather than vanishing.
    private var ratedReadbackChips: [MoodRatedReadbackChip] {
        entry.ratedFactors.map { factor in
            let dto = tagCatalog.catalog.categories
                .flatMap(\.tags)
                .first { $0.key == factor.key }
            let label = dto?.localizedLabel ?? MoodTagCatalogL10n.resolve(factor.key)
            // Resolve against a concrete catalog DTO when known (so the
            // inverse flag + scale are honoured); else a sane default scale.
            let resolveDTO = dto ?? MoodTagDTO(key: factor.key, labelKey: factor.key, icon: nil, kind: .rated)
            let quality = MoodRatedQuality.resolve(rating: factor.rating, factor: resolveDTO)
            let symbol = dto.map { MoodTagSFSymbol.symbol(forTag: $0) } ?? "slider.horizontal.3"
            return MoodRatedReadbackChip(
                key: factor.key,
                label: label,
                qualityWord: quality.localizedWord,
                symbol: symbol
            )
        }
    }

    private var moodTagChipRow: some View {
        MoodTagReadbackRow(chips: structuredTagChips, ratedChips: ratedReadbackChips)
    }

    var body: some View {
        HStack(alignment: .center, spacing: HLSpace.md) {
            Image(MoodCopy.iconName(for: entry.score))
                .resizable()
                .scaledToFit()
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: HLSpace.xs) {
                HStack(spacing: HLSpace.sm) {
                    Text(MoodCopy.scoreLabel(entry.score))
                        .font(.hlHeadline)
                        .foregroundStyle(HLText.primary)
                    Text(Self.relativeFormatter.localizedString(for: entry.recordedAt, relativeTo: .now))
                        .font(.hlCaption)
                        .foregroundStyle(HLText.tertiary)
                }
                if !structuredTagChips.isEmpty || !ratedReadbackChips.isEmpty {
                    moodTagChipRow
                }
                if !displayedTags.isEmpty {
                    Text(displayedTags.joined(separator: " · "))
                        .font(.hlCaption)
                        .foregroundStyle(HLText.secondary)
                        .lineLimit(1)
                }
                if let note = entry.note, !note.isEmpty {
                    Text(note)
                        .font(.hlCaption)
                        .foregroundStyle(HLText.secondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Free-text tag chip

struct TagChip: View {
    let label: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: HLSpace.xs) {
                Image(systemName: selected ? "checkmark" : "plus")
                    .font(.hlIcon(HLIconSize.xs))
                Text(label)
                    .font(.hlCaption)
            }
            .padding(.horizontal, HLSpace.md)
            .padding(.vertical, HLSpace.chip)
            .foregroundStyle(selected ? HLColor.background : HLText.primary)
            .background(
                Capsule()
                    .fill(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.clear))
            )
            .overlay(
                Capsule()
                    .stroke(
                        selected ? Color.clear : HLText.tertiary.opacity(0.3),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
