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
    /// Structured mood-tag catalog (for ordering the selected keys).
    @Environment(MoodTagCatalogStore.self) private var tagCatalog
    @Environment(\.dismiss) private var dismiss
    /// QoL-A2 (Felt-craft #5) — gate the mood-tap scale bounce on reduce-motion.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var selectedDate: Date = .now
    @State private var showDatePicker = false
    @State private var lastTappedScore: Int?
    @State private var tapCount: Int = 0
    /// Bumped on every face tap (before the network write) so the light impact plays the instant
    /// the user commits — independent of the `.success` cue (`tapCount`) that only fires on a confirmed save.
    @State private var tapImpactCount: Int = 0
    /// The annotation saved, but the server dropped some tag/factor keys.
    @State private var showDroppedKeys = false

    // MARK: - Inline annotate

    /// The just-logged entry awaiting optional annotation. Non-nil reveals
    /// the brief annotate panel (note field + on-device tag-suggest chips +
    /// "Fertig"). `nil` = no panel (fast path / pre-log).
    @State private var annotatingEntry: MoodEntry?
    /// Free-text note the user is typing in the annotate panel.
    @State private var annotateNote: String = ""
    /// Manual free-text tags and accepted on-device suggestions share the same
    /// bounded `[String]` wire collection.
    @State private var annotateTags: [String] = []
    /// Structured mood-tag keys picked from the Daylio-style catalog
    /// grid (multi-select across categories). Sent as `tagKeys` on save.
    @State private var annotateTagKeys: Set<String> = []
    /// On-device suggestions surfaced from the note text.
    @State private var annotateSuggestions: [MoodTagSuggestion] = []
    @State private var isSuggesting = false
    /// Mood v2 rated factors. `factorKey → rating`. A factor the
    /// user never touched is absent (no "0" rating) and is simply not sent.
    @State private var annotateRatings: [String: Int] = [:]
    @FocusState private var annotateNoteFocused: Bool
    /// Host-sheet detent, driven programmatically. Pre-log the sheet sits compact (`.medium`)
    /// over just the hero + 5 faces; the moment a mood is logged (`annotatingEntry != nil`) it grows to a tall
    /// detent so the whole annotate panel — sliders + tag grid + tag-management link + note + "Fertig" — is
    /// visible WITHOUT internal scrolling. The growth animates (reduce-motion gated) so the surface "opens wide".
    @State private var sheetDetent: PresentationDetent = .medium

    /// The tall detent the sheet grows to once a mood is logged: the large
    /// detent of the standard sheet size, so the annotate panel fits whole.
    private static let annotateDetent: PresentationDetent = .large

    /// "Donnerstag, 12. Nov., 08:05": the day in words, the time in the
    /// person's 12- or 24-hour setting.
    private static func dateHeader(_ date: Date) -> String {
        "\(HLDateFormat.weekdayDayMonth(date)), \(HLTimeFormat.time(date))"
    }

    var body: some View {
        NavigationStack {
            HLPage {
                pickerHero
            }
            // The head of every other sheet: close leading, the question
            // inline in the bar.
            .hlSheetHead(title: "How are you?")
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
            .hlAcknowledgeAlert("mood.droppedKeys.title", message: "mood.droppedKeys.message", isPresented: $showDroppedKeys) { dismiss() }
        }
        // Own the host-sheet detent so the screen can grow itself the
        // moment a mood is logged: `.medium` over the hero and faces, then the
        // large detent so the whole annotate panel fits without scrolling. The
        // inner presentation wins over the call-site default. In a regular
        // window the same presentation (the one `HLSheetScaffold` uses) is a
        // form sheet at its final size from the start, so nothing grows there.
        .hlSheetPresentation(.standard, selection: $sheetDetent)
        .onChange(of: annotatingEntry?.id) { _, newValue in
            // Grow on first log; never auto-shrink mid-annotation (the user may
            // drag down themselves). Reduce-motion gates the grow animation.
            guard newValue != nil else { return }
            withAnimation(reduceMotion ? nil : HLMotion.spring) {
                sheetDetent = Self.annotateDetent
            }
        }
    }

    // MARK: - Hero picker

    private var pickerHero: some View {
        VStack(spacing: HLLayout.cardGap) {
            // The day and time as the app's quiet link: a tap opens the
            // back-log picker.
            HLLinkButton(Text(Self.dateHeader(selectedDate)), systemImage: "calendar") {
                showDatePicker = true
            }
            .accessibilityLabel(Text("Pick date"))
            .accessibilityValue(Text(Self.dateHeader(selectedDate)))

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

    // MARK: - Annotate panel

    private var annotatePanel: some View {
        HLCard {
            annotatePanelContent
        }
    }

    private var annotatePanelContent: some View {
        VStack(alignment: .leading, spacing: HLSpace.md) {
            // Every server-visible rated factor comes first, before the binary
            // tag grid. The catalog owns both membership and order.
            ratedFactorsSection

            // Daylio-style structured tag grid (context after the
            // sliders). The panel STAYS OPEN while the user selects
            // tags / rates factors / types a note. The old grace-window
            // auto-dismiss is gone — only explicit "Fertig" (`commitAnnotation`)
            // or a swipe-down of the host sheet closes it.
            MoodTagPicker(selectedKeys: $annotateTagKeys)

            // v1.13.0 — lightweight entry into the custom-tag management screen
            // (create / edit / hide tags). On-doctrine: a quiet text link, not a
            // prominent button, so it never competes with the capture flow.
            HLLinkButton(
                "mood.tags.manage.entry",
                systemImage: "slider.horizontal.3",
                alignment: .leading,
                destination: { MoodTagManagementScreen() }
            )
            .accessibilityIdentifier("mood.annotate.manageTags")

            // Note field with the on-device tag-suggest folded INLINE on the
            // same row: a quiet trailing sparkle button instead of a
            // separate stacked suggest panel below, reclaiming the vertical
            // space the old block ate. Same `runAnnotateSuggest()` behaviour +
            // disabled / progress / fallback states — just relocated.
            noteRow

            MoodFreeTextTagInput(tags: $annotateTags)

            // Suggested tags surfaced from the note (only after a run).
            if store.supportsTagSuggestions, !annotateSuggestions.isEmpty {
                HLFlowLayout {
                    ForEach(annotateSuggestions) { suggestion in
                        HLChip(verbatim: suggestion.label, systemImage: "plus", isSelected: false) {
                            acceptSuggestion(suggestion)
                        }
                    }
                }
            }

            HLButton("mood.annotate.done", variant: .secondary) {
                Task { await commitAnnotation() }
            }
            .accessibilityIdentifier("mood.annotate.done")
        }
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
                HLIconButton(
                    systemImage: "sparkles",
                    label: "mood.annotate.suggest",
                    size: .inline,
                    isLoading: isSuggesting
                ) {
                    Task { await runAnnotateSuggest() }
                }
                .disabled(annotateNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityHint(Text("mood.annotate.suggest.hint"))
            }
        }
        .padding(HLSpace.md)
        .background(HLSurface.tertiary)
        .clipShape(RoundedRectangle(cornerRadius: HLRadius.sm, style: .continuous))
    }

    private var iconRow: some View {
        // At the accessibility sizes the five faces stand one under the
        // other, each with its word beside it: in a row of five, „Super"
        // broke into „Su / per" and „Schlecht" was cut.
        let stacked = dynamicTypeSize.isAccessibilitySize
        let layout = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: HLSpace.sm))
            : AnyLayout(HStackLayout(alignment: .top, spacing: HLSpace.md))
        return layout {
            // v0.6.1.19 Y10.5 (g): horizontal order is best-on-the-left,
            // worst-on-the-right per operator brief. Score 5 (Super)
            // first, score 1 (Lausig) last — matching the natural
            // left-to-right reading rhythm "I'd rather be over here".
            ForEach(Array((1 ... 5).reversed()), id: \.self) { value in
                moodIconButton(value, stacked: stacked)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func moodIconButton(_ value: Int, stacked: Bool) -> some View {
        Button {
            Task { await record(score: value) }
        } label: {
            let layout = stacked
                ? AnyLayout(HStackLayout(spacing: HLSpace.md))
                : AnyLayout(VStackLayout(spacing: HLSpace.xs))
            layout {
                Image(MoodCopy.iconName(for: value))
                    .resizable()
                    .scaledToFit()
                    .frame(width: 56, height: 56)
                    .scaleEffect(lastTappedScore == value ? 1.08 : 1.0)
                    .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.6), value: lastTappedScore)
                    // The saved face gets the app's drawn check at its
                    // corner, the same as a taken dose and a saved value. It
                    // follows the stored entry, never the last tap: a tap
                    // whose save fails confirms nothing.
                    .overlay(alignment: .bottomTrailing) {
                        let confirmed = Self.confirmsFace(value, savedScore: annotatingEntry?.score)
                        HLConfirmGlyph(isConfirmed: confirmed)
                            .font(.hlIcon(HLIconSize.lg))
                            .foregroundStyle(HLColor.statusOK)
                            // The disc stands only under a drawn check; on the
                            // other faces it cut a bite out of the face.
                            .background(Circle().fill(HLSurface.primary).padding(HLSpace.xxs).opacity(confirmed ? 1 : 0))
                            .offset(x: HLSpace.xs, y: HLSpace.xs)
                    }
                    .accessibilityHidden(true)
                Text(MoodCopy.scoreLabel(value))
                    .hlText(.rowSubtitle)
                    .lineLimit(stacked ? nil : 2) // A second line instead of a smaller word.
                    .multilineTextAlignment(stacked ? .leading : .center)
            }
            .frame(maxWidth: .infinity, alignment: stacked ? .leading : .center)
            .contentShape(Rectangle())
        }
        .buttonStyle(.hlRow)
        .accessibilityLabel(Text(MoodCopy.accessibilityLabel(for: value)))
        .accessibilityValue(Text("\(value) of 5"))
        .accessibilityIdentifier("mood.face.\(value)")
    }

    /// Whether the face of `value` carries the check: only the face of the
    /// entry the store saved.
    nonisolated static func confirmsFace(_ value: Int, savedScore: Int?) -> Bool {
        savedScore == value
    }

    private func record(score: Int) async {
        // Declarative light impact via `.sensoryFeedback` — fires the
        // moment the tap commits (reduce-motion / accessibility aware).
        tapImpactCount += 1
        lastTappedScore = score
        // Undo-aware quick log: the store enqueues a `Rückgängig`
        // toast (hosted by AuthenticatedShell) so a mis-tapped face is
        // reversible even after the sheet auto-dismisses.
        let saved = await store.logUndoable(score: score, recordedAt: selectedDate)
        if let saved {
            tapCount += 1
            // Instead of a hard auto-dismiss, reveal the
            // optional annotate panel (rated sliders + tag grid + note + on-device
            // tag-suggest) so the daily flow can reach the context that is the
            // value in a mood tracker. The panel now also GROWS the host
            // sheet to a tall detent (via `onChange(of: annotatingEntry?.id)`) so
            // everything is visible without internal scrolling. The panel STAYS
            // OPEN until explicit "Fertig" (`commitAnnotation`) or a swipe-down of
            // the host sheet — there is no grace-window auto-dismiss.
            annotatingEntry = saved
            annotateNote = saved.note ?? ""
            annotateTags = []
            annotateTagKeys = Set(saved.tagKeys)
            // Pre-fill the rated sliders from the entry's decoded
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
        // Mood v2 rated factors. Only factors the user actually
        // touched are sent (omit = no rating); clamp client-side to the catalog
        // scale so the server never 422s on out-of-range (contract §3).
        let factors = ratedFactorsPayload()
        if !trimmedNote.isEmpty || !annotateTags.isEmpty || !tagKeys.isEmpty || !factors.isEmpty {
            _ = await store.update(
                entry,
                // `nil` for an unnameable level: the annotation is
                // saved and the level is left exactly as the server holds it.
                score: entry.score,
                tags: annotateTags,
                tagKeys: tagKeys,
                ratedFactors: factors,
                recordedAt: entry.recordedAt,
                note: trimmedNote.isEmpty ? nil : trimmedNote
            )
        }
        annotatingEntry = nil
        if store.lastWriteDroppedKeys.isEmpty { dismiss() } else { showDroppedKeys = true } // Tell, then close
    }

    /// Project the selected tag-key set into a stable, catalog-ordered array.
    private func catalogOrderedSelection() -> [String] {
        tagCatalog.catalog.orderedKeys(from: annotateTagKeys)
    }

    // MARK: - Mood v2 rated factors

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
                    HLCardLabel("mood.ratedFactors.title")
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                // R4 de-nest: sliders render directly here (no wrapping card /
                // 3rd background) — only this header + the rows, calmer chrome.
                VStack(alignment: .leading, spacing: HLLayout.cardGap) {
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
        HLSheetScaffold("Backdate entry", size: .standard, action: .done { showDatePicker = false }) {
            HLPage {
                DatePicker(
                    String(localized: "Date & time"),
                    selection: $selectedDate,
                    in: Self.allowedDateRange,
                    displayedComponents: [.date, .hourAndMinute]
                )
                .datePickerStyle(.graphical)
                // Back to now under the calendar, the quiet link of the app.
                HLLinkButton("Today", systemImage: "calendar") {
                    selectedDate = .now
                }
            }
        }
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
    /// **The label for a possibly-unnameable level.**
    ///
    /// `nil` is not a sixth point on the scale and gets no glyph from the pack:
    /// it is the neutral "Mood unknown" chip, which is the whole visible shape
    /// of the sentinel on this screen.
    static func levelLabel(_ score: Int?) -> String {
        guard let score else { return String(localized: "mood.level.unknown") }
        return scoreLabel(score)
    }

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
