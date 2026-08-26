import SwiftUI

/// Presented from `MoodHistoryScreen` row swipe-action "Bearbeiten" (and the
/// Insights mood page / recent-section edit affordances).
///
/// **v0.14.9 (W-B187) — edit reuses the SAME structured surface as capture.**
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
    @State private var isSaving: Bool = false
    @State private var error: HLError?
    // D-2 — on-device tag-suggestion state
    @State private var suggestions: [MoodTagSuggestion] = []
    @State private var isSuggesting = false
    @State private var suggestionError: MoodTagSuggestionOutcome.FallbackReason?
    /// Bumped when a tag suggestion is accepted so the light impact plays
    /// declaratively via `.sensoryFeedback` (reduce-motion aware).
    @State private var acceptPulse: Int = 0

    var body: some View {
        NavigationStack {
            Form {
                Section("Mood") {
                    moodPickerRow
                }
                // The Mood-v2 RATED sliders (Arbeit / Schlafqualität /
                // Traurigkeit), mirroring `MoodScreen`'s inline annotate panel so
                // editing from Insights/History shows + round-trips the saved
                // ratings. Self-suppresses when the catalog ships no rated factor.
                if !ratedFactors.isEmpty {
                    Section("mood.ratedFactors.title") {
                        VStack(alignment: .leading, spacing: HLSpace.lg) {
                            ForEach(ratedFactors) { factor in
                                MoodRatedFactorRow(factor: factor, rating: Binding(
                                    get: { ratings[factor.key] },
                                    set: { ratings[factor.key] = $0 }
                                ), reduceMotion: reduceMotion)
                            }
                        }
                        .padding(.vertical, HLSpace.xxs)
                    }
                }
                // W-B187 — the SAME structured Daylio-style tag grid capture
                // uses (`MoodScreen.annotatePanel`). Edits the entry's REAL
                // `tagKeys` against the server catalog; no hardcoded list, no
                // clobber.
                Section("Tags") {
                    MoodTagPicker(selectedKeys: $tagKeys)
                        .padding(.vertical, HLSpace.xxs)
                }
                Section("Time") {
                    DatePicker("Recorded at", selection: $recordedAt, displayedComponents: [.date, .hourAndMinute])
                }
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
                if let error {
                    Section { HLFormErrorText(error.localizedDescription) }
                }
            }
            .navigationTitle("Edit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onDismiss)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await save() }
                    }
                    .disabled(isSaving)
                }
            }
            .onAppear(perform: prefill)
            .sensoryFeedback(.impact(weight: .light), trigger: acceptPulse)
        }
        .interactiveDismissDisabled(isSaving)
    }

    /// The kanonical Mood-Icon-Pack (`Image(MoodCopy.iconName(for:))`, the PNG
    /// assets the capture picker (`MoodScreen.iconRow`) + history rows render)
    /// with the SAME labelled score vocabulary (`MoodCopy.scoreLabel`) capture
    /// shows — icon-only/divergent-vocabulary is retired (W-B187). Form-Section
    /// is tighter than the capture card → 40pt glyph + a caption label, tap
    /// target still ≥44pt via `minHeight`.
    private var moodPickerRow: some View {
        HStack(alignment: .top, spacing: HLSpace.sm) {
            ForEach(1 ... 5, id: \.self) { value in
                moodPickerButton(value)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, HLSpace.xs)
    }

    private func moodPickerButton(_ value: Int) -> some View {
        Button {
            score = value
        } label: {
            VStack(spacing: HLSpace.xs) {
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
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(MoodCopy.accessibilityLabel(for: value)))
        .accessibilityValue(Text("\(value) of 5"))
        .accessibilityAddTraits(score == value ? .isSelected : [])
    }

    // MARK: - D-2 on-device tag-suggestion UX

    /// The on-device tag-suggest as a compact trailing button folded onto the
    /// note row (quiet sparkle / spinner). Same `runSuggest()` behaviour +
    /// disabled state as capture.
    private var suggestTagsButton: some View {
        Button {
            Task { await runSuggest() }
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
        .disabled(isSuggesting || note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .accessibilityLabel(Text("Suggest tags"))
        .accessibilityHint(Text("Suggests tags from your note text with an on-device model. You confirm each tag yourself."))
    }

    private var suggestionsPanel: some View {
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            HStack(spacing: HLSpace.sm) {
                HLSectionLabel("Suggestions")
                Spacer()
                Button {
                    suggestions = []
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.hlIcon(HLIconSize.sm, weight: .regular))
                        .foregroundStyle(HLText.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Hide suggestions"))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: HLSpace.sm) {
                    ForEach(suggestions) { suggestion in
                        SuggestedTagChip(label: suggestion.label) {
                            accept(suggestion)
                        }
                    }
                }
                .padding(.vertical, HLSpace.xxs)
            }
            Text("Suggestions are non-binding. Tap a tag to apply it.")
                .font(.hlCaption)
                .foregroundStyle(HLText.tertiary)
        }
    }

    private func suggestionFallbackRow(_ reason: MoodTagSuggestionOutcome.FallbackReason) -> some View {
        Text(suggestionFallbackMessage(reason))
            .font(.hlCaption)
            .foregroundStyle(HLText.tertiary)
    }

    private func suggestionFallbackMessage(_ reason: MoodTagSuggestionOutcome.FallbackReason) -> String {
        switch reason {
        case .featureFlagDisabled:
            String(localized: "Tag suggestions are currently disabled.")
        case .deviceIneligible, .appleIntelligenceDisabled, .modelNotReady, .frameworkUnavailable:
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
        score = entry.score
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
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
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
        if ok {
            onDismiss()
        } else {
            error = store.error ?? .unknown(String(localized: "Could not save"))
        }
    }
}

// MARK: - Suggested-tag chip (D-2)

/// Visually distinct from `TagChip`: dashed purple outline + sparkle glyph,
/// makes "this is a suggestion, not a confirmed tag" unmistakable. Tap
/// promotes it into `acceptedTags` and removes it from the suggestion row.
struct SuggestedTagChip: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: HLSpace.xs) {
                Image(systemName: "sparkles")
                    .font(.hlIcon(HLIconSize.xs))
                Text(label)
                    .font(.hlCaption)
            }
            .padding(.horizontal, HLSpace.md)
            .padding(.vertical, HLSpace.chip)
            .foregroundStyle(.tint)
            .overlay(
                Capsule()
                    .strokeBorder(
                        .tint.opacity(0.5),
                        style: StrokeStyle(lineWidth: 1, dash: [3, 2])
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Suggestion \(label)"))
        .accessibilityHint(Text("Tap to apply the tag."))
    }
}
