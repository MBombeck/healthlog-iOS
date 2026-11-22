import SwiftUI

/// Presented from `MoodHistoryScreen` row swipe-action "Bearbeiten" (and the
/// Insights mood page / recent-section edit affordances).
///
/// **Edit reuses the SAME structured surface as capture.**
/// The legacy hardcoded `defaultTags`/`rawTags` chip grid is gone: editing an
/// entry now drives the SAME ``MoodTagPicker`` (structured `tagKeys`, server
/// catalog) that `MoodScreen`'s capture panel uses, so a re-save round-trips
/// the entry's REAL structured tags instead of clobbering them with a divergent
/// hardcoded list. The 5-face score picker now shows the SAME labelled
/// vocabulary (`MoodCopy.scoreLabel`) as capture — icon-only with a divergent
/// vocabulary is retired.
///
/// Free-text AI tag-suggestions (the on-device sparkle flow) remain a SEPARATE,
/// removable chip list below the note — exactly as in capture (`annotateTags`)
/// — and `entry.tags` (legacy free-text labels) are pre-loaded there so they
/// are preserved across an edit, never dropped. Note is a dedicated field
/// (Server v1.4.30 `MoodEntry.note`), never a `tags["note:..."]` hack.
struct EditMoodSheet: View {
    let entry: MoodEntry
    let onDismiss: () -> Void

    @Environment(MoodStore.self) private var store
    /// The structured mood-tag catalog (RATED factors + ordering + the binary
    /// tag grid), mirroring `MoodScreen`'s inline annotate panel so the
    /// Insights/History editor reaches the same Mood-v2 contract.
    @Environment(MoodTagCatalogStore.self) private var tagCatalog
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var score: Int = 3
    @State private var recordedAt: Date = .now
    @State private var note: String = ""
    /// Free-text tags — the entry's legacy labels + AI-accepted suggestions.
    /// Kept distinct from the structured `tagKeys` (the picker grid), exactly
    /// like capture's `annotateTags` vs `annotateTagKeys`.
    @State private var acceptedTags: [String] = []
    /// Mood-v2 rated factors (`factorKey → rating`). Prefilled from
    /// `entry.ratedFactors`; an untouched factor is absent (never sent as "0").
    @State private var ratings: [String: Int] = [:]
    /// Structured tag-key selection (the `MoodTagPicker` grid), prefilled from
    /// `entry.tagKeys` and round-tripped on save.
    @State private var tagKeys: Set<String> = []
    @State private var error: HLError?
    // On-device tag-suggestion state
    @State private var suggestions: [MoodTagSuggestion] = []
    @State private var isSuggesting = false
    @State private var suggestionError: MoodTagSuggestionOutcome.FallbackReason?
    /// Bumped when a tag suggestion is accepted so the light impact plays
    /// declaratively via `.sensoryFeedback` (reduce-motion aware).
    @State private var acceptPulse: Int = 0
    /// The save landed but the server dropped some tag/factor keys.
    @State private var showDroppedKeys = false
    /// The entry as prefilled, for the discard guard.
    @State private var baseline: [AnyHashable]?

    var body: some View {
        HLSheetScaffold(
            "Edit",
            action: .save { await save() },
            isDirty: isDirty
        ) {
            Form {
                Section("Mood") {
                    moodPickerRow
                }
                .hlFormRowSurface()
                // The Mood-v2 RATED sliders (Arbeit / Schlafqualität /
                // Traurigkeit), mirroring `MoodScreen`'s inline annotate panel so
                // editing from Insights/History shows + round-trips the saved
                // ratings. Self-suppresses when the catalog ships no rated factor.
                if !ratedFactors.isEmpty {
                    Section("mood.ratedFactors.title") {
                        VStack(alignment: .leading, spacing: HLLayout.cardGap) {
                            ForEach(ratedFactors) { factor in
                                MoodRatedFactorRow(factor: factor, rating: Binding(
                                    get: { ratings[factor.key] },
                                    set: { ratings[factor.key] = $0 }
                                ), reduceMotion: reduceMotion)
                            }
                        }
                        .padding(.vertical, HLSpace.xxs)
                    }
                    .hlFormRowSurface()
                }
                // The SAME structured Daylio-style tag grid capture
                // uses (`MoodScreen.annotatePanel`). Edits the entry's REAL
                // `tagKeys` against the server catalog; no hardcoded list, no
                // clobber.
                Section("Tags") {
                    MoodTagPicker(selectedKeys: $tagKeys)
                        .padding(.vertical, HLSpace.xxs)
                }
                .hlFormRowSurface()
                Section("Time") {
                    DatePicker(selection: $recordedAt, displayedComponents: [.date, .hourAndMinute]) {
                        HLRowTitle("Recorded at")
                    }
                }
                .hlFormRowSurface()
                Section("Note") {
                    // Fold the on-device tag-suggest onto the note row itself (a
                    // quiet trailing sparkle button), mirroring MoodScreen's
                    // capture panel and reclaiming the vertical space.
                    HStack(alignment: .center, spacing: HLSpace.sm) {
                        TextField("Optional", text: $note, axis: .vertical).lineLimit(2 ... 4)
                        if store.supportsTagSuggestions {
                            suggestTagsButton
                        }
                    }
                    MoodFreeTextTagInput(tags: $acceptedTags)
                    if !suggestions.isEmpty {
                        suggestionsPanel
                    } else if let fallback = suggestionError {
                        suggestionFallbackRow(fallback)
                    }
                }
                .hlFormRowSurface()
                if let error {
                    Section { HLFormErrorText(error.userFacingDescription) }
                        .hlFormRowSurface()
                }
            }
            .hlPageMargins()
            .onAppear(perform: prefill)
            .sensoryFeedback(.impact(weight: .light), trigger: acceptPulse)
            .hlAcknowledgeAlert(
                "mood.droppedKeys.title",
                message: "mood.droppedKeys.message",
                isPresented: $showDroppedKeys,
                onAcknowledge: onDismiss
            )
        }
    }

    /// Every field the person can change, in one comparable value.
    private var formFingerprint: [AnyHashable] {
        [score, recordedAt, note, acceptedTags, ratings, tagKeys]
    }

    private var isDirty: Bool {
        guard let baseline else { return false }
        return baseline != formFingerprint
    }

    /// The kanonical Mood-Icon-Pack (`Image(MoodCopy.iconName(for:))`, the PNG
    /// assets the capture picker (`MoodScreen.iconRow`) + history rows render)
    /// with the SAME labelled score vocabulary (`MoodCopy.scoreLabel`) capture
    /// shows — icon-only/divergent-vocabulary is retired. Form-Section
    /// is tighter than the capture card → 40pt glyph + a caption label, tap
    /// target still ≥44pt via `minHeight`.
    ///
    /// At the accessibility sizes the faces stand one under the other with
    /// the word beside them, like the capture picker.
    private var moodPickerRow: some View {
        let stacked = dynamicTypeSize.isAccessibilitySize
        let layout = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: HLSpace.xs))
            : AnyLayout(HStackLayout(alignment: .top, spacing: HLSpace.sm))
        return layout {
            ForEach(1 ... 5, id: \.self) { value in
                moodPickerButton(value, stacked: stacked)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, HLSpace.xs)
    }

    private func moodPickerButton(_ value: Int, stacked: Bool) -> some View {
        Button {
            score = value
        } label: {
            let layout = stacked
                ? AnyLayout(HStackLayout(spacing: HLSpace.md))
                : AnyLayout(VStackLayout(spacing: HLSpace.xs))
            layout {
                ZStack {
                    Circle()
                        .stroke(
                            score == value ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.clear),
                            lineWidth: 2
                        )
                        .frame(width: 48, height: 48)
                    Image(MoodCopy.iconName(for: value))
                        .resizable()
                        .scaledToFit()
                        .frame(width: 40, height: 40)
                        .scaleEffect(score == value ? 1.05 : 1.0)
                        .accessibilityHidden(true)
                }
                .frame(minHeight: 48)
                Text(MoodCopy.scoreLabel(value))
                    .font(.hlCaption)
                    .foregroundStyle(score == value ? AnyShapeStyle(.tint) : AnyShapeStyle(HLText.secondary))
                    // A second line instead of a smaller word.
                    .lineLimit(stacked ? nil : 2)
                    .multilineTextAlignment(stacked ? .leading : .center)
            }
            .frame(maxWidth: .infinity, alignment: stacked ? .leading : .center)
            .contentShape(Rectangle())
        }
        .buttonStyle(.hlRow)
        .accessibilityLabel(Text(MoodCopy.accessibilityLabel(for: value)))
        .accessibilityValue(Text("\(value) of 5"))
        .accessibilityAddTraits(score == value ? .isSelected : [])
    }

    // MARK: - On-device tag-suggestion UX

    /// The on-device tag-suggest as a compact trailing button folded onto the
    /// note row (quiet sparkle / spinner). Same `runSuggest()` behaviour +
    /// disabled state as capture.
    private var suggestTagsButton: some View {
        HLIconButton(systemImage: "sparkles", label: "Suggest tags", size: .inline, isLoading: isSuggesting) {
            Task { await runSuggest() }
        }
        .disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .accessibilityHint(Text("Suggests tags from your note text with an on-device model. You confirm each tag yourself."))
    }

    private var suggestionsPanel: some View {
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            HStack(spacing: HLSpace.sm) {
                HLCardLabel("Suggestions")
                Spacer()
                HLIconButton(systemImage: "xmark", label: "Hide suggestions", size: .inline) {
                    suggestions = []
                }
            }
            HLFlowLayout {
                ForEach(suggestions) { suggestion in
                    HLChip(verbatim: suggestion.label, systemImage: "sparkles", isSelected: false) {
                        accept(suggestion)
                    }
                    .accessibilityLabel(Text("Suggestion \(suggestion.label)"))
                    .accessibilityHint(Text("Tap to apply the tag."))
                }
            }
            // The chips are plainly offers; no line says so.
        }
    }

    private func suggestionFallbackRow(_ reason: MoodTagSuggestionOutcome.FallbackReason) -> some View {
        Text(suggestionFallbackMessage(reason))
            .hlText(.footnote)
    }

    private func suggestionFallbackMessage(_ reason: MoodTagSuggestionOutcome.FallbackReason) -> String {
        switch reason {
        case .capabilityNotAllowed:
            String(localized: "Tag suggestions are currently disabled.")
        case .deviceIneligible, .appleIntelligenceDisabled, .modelNotReady, .frameworkUnavailable, .languageUnsupported:
            String(localized: "On-device suggestions are not available on this device.")
        case .safetyRefused:
            String(localized: "Suggestions were held back by the safety filter.")
        case .generationFailed:
            String(localized: "Could not generate suggestions. Try again later.")
        case .emptyInput:
            String(localized: "Write something in the note to enable suggestions.")
        }
    }

    private func runSuggest() async {
        suggestionError = nil
        isSuggesting = true
        defer { isSuggesting = false }
        let outcome = await store.suggestTags(forNote: note, existingTags: acceptedTags)
        guard let outcome else {
            suggestions = []
            return
        }
        if let list = outcome.suggestions {
            suggestions = list
            if list.isEmpty {
                // Empty success means the model found nothing relevant.
                suggestionError = .emptyInput
            }
        } else {
            suggestions = []
            suggestionError = outcome.fallbackReason
        }
    }

    private func accept(_ suggestion: MoodTagSuggestion) {
        acceptPulse += 1
        var updated = acceptedTags
        _ = MoodFreeTextTagRules.insert(suggestion.label, into: &updated)
        acceptedTags = updated
        suggestions.removeAll { $0.id == suggestion.id }
    }

    // MARK: - Mood v2 rated factors (mirror of MoodScreen)

    /// Every VISIBLE RATED factor in the catalog, in catalog order —
    /// identical projection to `MoodScreen.ratedFactors`.
    private var ratedFactors: [MoodTagDTO] {
        tagCatalog.catalog.categories.flatMap { $0.tags.filter(MoodTagCatalog.isVisibleRated) }
    }

    /// Touched ratings → wire payload, clamped to each factor's own scale so the
    /// server never 422s; untouched factors are omitted (no "0" rating). Exact
    /// mirror of `MoodScreen.ratedFactorsPayload()`.
    private func ratedFactorsPayload() -> [RatedFactorInput] {
        ratedFactors.compactMap { factor in
            guard let raw = ratings[factor.key] else { return nil }
            return RatedFactorInput(key: factor.key, rating: min(max(raw, factor.scaleMin), factor.scaleMax))
        }
    }

    /// Project the selected tag-key set into a stable, catalog-ordered array
    /// (mirror of `MoodScreen.catalogOrderedSelection()`).
    private func catalogOrderedSelection() -> [String] {
        tagCatalog.catalog.orderedKeys(from: tagKeys)
    }

    private func prefill() {
        // An entry whose level this build cannot name pre-fills the
        // picker at the neutral middle. That is a suggestion the person then
        // confirms with their own tap, not a claim the app files on their
        // behalf: saving the sheet is an explicit re-statement of the level.
        score = entry.score ?? 3
        recordedAt = entry.recordedAt
        note = entry.note ?? ""
        // Free-text legacy labels are pre-loaded as removable chips so they are
        // preserved across an edit (never silently dropped). Note-hack entries
        // were already migrated server-side (v1.4.30).
        acceptedTags = entry.tags.filter { !$0.hasPrefix("note:") }
        // Pre-fill the rated sliders + structured tag-keys from the entry so
        // editing shows the saved ratings (not "nicht bewertet") and the picker
        // shows the saved tags, and a re-save never silently drops them. Exact
        // mirror of MoodScreen:367-377.
        ratings = Dictionary(
            entry.ratedFactors.map { ($0.key, $0.rating) },
            uniquingKeysWith: { first, _ in first }
        )
        tagKeys = Set(entry.tagKeys)
        if baseline == nil { baseline = formFingerprint }
    }

    /// `true` closes the sheet. A save whose keys the server dropped stays
    /// open until the person has read why; the alert then closes it.
    private func save() async -> Bool {
        error = nil
        // Single-write: `note` als dediziertes Feld, kein `tags["note:..."]`
        // Hack mehr. Pass the Mood-v2 args (structured tagKeys + clamped rated
        // factors) so the editor round-trips ratings + tags instead of silently
        // dropping them. Mirror of `MoodScreen.commitAnnotation()`.
        let ok = await store.update(
            entry,
            score: score,
            tags: acceptedTags,
            tagKeys: catalogOrderedSelection(),
            ratedFactors: ratedFactorsPayload(),
            recordedAt: recordedAt,
            note: note.isEmpty ? nil : note
        )
        if ok, !store.lastWriteDroppedKeys.isEmpty {
            // Saved, but tell the person before closing.
            showDroppedKeys = true
            return false
        } else if ok {
            onDismiss()
            return true
        } else {
            error = store.error ?? .unknown(String(localized: "Could not save"))
            return false
        }
    }
}
