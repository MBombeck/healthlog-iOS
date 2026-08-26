import SwiftUI

#if canImport(SpeziChat)
    import SpeziChat
#endif

// MARK: - Custom transcript + input row

// Split out of `AskCoachSheet.swift` (v0.14.1) to keep that file under the
// SwiftLint 600-line ceiling after the External-AI consent dead-end fix added
// the provider-needed step. These transcript views were `private` to
// `AskCoachSheet.swift`; moving them to their own file in the same module they
// become module-internal — `AskCoachSheet.chatView(store:)` still references
// `CoachTranscriptView`, so they cannot be `private` across files.

#if canImport(SpeziChat)
    /// Coach-owned transcript. Renders `store.chat` as alternating
    /// bubbles where **both** roles land on the same dark surface
    /// (charcoal-tone), so the operator never
    /// sees the white-on-light-grey legibility regression that
    /// SpeziChat's `MessageStyleModifier` produced.
    struct CoachTranscriptView: View {
        let store: CoachConversationStore
        var seed: String? // v0.13 WP — one-shot composer seed from a prompt chip
        @State private var draft: String = ""
        @State private var didApplySeed = false
        @FocusState private var inputFocused: Bool
        /// QoL-A2 (Felt-craft #5) — gate the transcript auto-scroll on
        /// reduce-motion (instant jump to tail when motion is disabled).
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        /// W-B187 COACH-3 — reach the shared about-me store + server gate so a
        /// "remember this" on a user turn folds the statement into the coach
        /// self-context. Only offered on a paired install (server present).
        @Environment(\.appContainer) private var appContainer
        @Environment(BackendAvailability.self) private var backend
        /// Quiet inline confirmation after a remember-this action.
        @State private var rememberNote: RememberNote?

        /// `.id`-able transient confirmation toast for the remember action.
        private struct RememberNote: Identifiable {
            let id = UUID()
            let success: Bool
        }

        var body: some View {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: HLSpace.md) {
                            ForEach(visibleEntries) { entity in
                                VStack(alignment: .leading, spacing: HLSpace.xs) {
                                    CoachMessageBubble(entity: entity)
                                        // W-B187 COACH-3 — long-press a user turn
                                        // to fold the statement into the coach
                                        // self-context (server matches the field).
                                        // Paired-install only (needs the server).
                                        .contextMenu {
                                            if canRemember(entity) {
                                                Button {
                                                    rememberStatement(entity.content)
                                                } label: {
                                                    Label(
                                                        String(localized: "coach.remember.action"),
                                                        systemImage: "brain.head.profile"
                                                    )
                                                }
                                            }
                                        }
                                    // CO4 (v0154) — the collapsed "what I'm
                                    // looking at" provenance disclosure under a
                                    // server-arm assistant reply. Server-arm only
                                    // (on-device / BYO carry no provenance).
                                    if isAssistant(entity),
                                       let provenance = store.provenanceByEntity[entity.id]
                                    {
                                        CoachProvenanceDisclosure(provenance: provenance)
                                    }
                                    // Server-parity: thumbs only on assistant
                                    // replies the server persisted (server-arm
                                    // turns carry a message id) — on-device /
                                    // BYO / hydrated rows never show the row.
                                    if isAssistant(entity), store.feedback.canRate(entityID: entity.id) {
                                        CoachFeedbackRow(store: store, entityID: entity.id)
                                    }
                                    // CO5 (v0154) — quiet per-turn token footer
                                    // under a server-arm reply. Server-arm only;
                                    // skipped when no count (on-device / BYO).
                                    if isAssistant(entity),
                                       let usage = store.usageByEntity[entity.id]
                                    {
                                        CoachTokenFooter(usage: usage)
                                    }
                                }
                                .id(entity.id)
                            }
                            // v1.18.1 (§3) — coach cadence suggestion: an
                            // actionable card under the latest reply, or a quiet
                            // "created" confirmation after the user accepts.
                            if let suggestion = store.pendingSuggestion {
                                CoachSuggestionCard(
                                    suggestion: suggestion,
                                    onAccept: { Task { await store.actOnSuggestion(.accept) } },
                                    onDismiss: { Task { await store.actOnSuggestion(.dismiss) } },
                                    onStop: { Task { await store.actOnSuggestion(.stop) } }
                                )
                                .id("coach-suggestion")
                            } else if store.lastSuggestionAction == .accept {
                                CoachSuggestionAcceptedNote()
                                    .id("coach-suggestion-accepted")
                            }
                            if store.isResponding {
                                CoachTypingBubble()
                                    .id("typing-indicator")
                            }
                            // Tail anchor so we always scroll to the
                            // newest content (entity OR indicator).
                            Color.clear
                                .frame(height: 1)
                                .id("transcript-tail")
                        }
                        .padding(.horizontal, HLSpace.lg)
                        .padding(.vertical, HLSpace.md)
                    }
                    .onChange(of: store.chat) { _, _ in
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                            proxy.scrollTo("transcript-tail", anchor: .bottom)
                        }
                    }
                    .onChange(of: store.isResponding) { _, _ in
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                            proxy.scrollTo("transcript-tail", anchor: .bottom)
                        }
                    }
                    // v1.18.1 (§3) — bring a freshly-arrived cadence card into view.
                    .onChange(of: store.pendingSuggestion) { _, _ in
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                            proxy.scrollTo("transcript-tail", anchor: .bottom)
                        }
                    }
                }
                CoachInputRow(
                    draft: $draft,
                    focused: $inputFocused,
                    isResponding: store.isResponding
                ) { Task { await submit() } }
            }
            .onAppear(perform: applySeedIfNeeded)
            .overlay(alignment: .bottom) {
                if let note = rememberNote {
                    rememberToast(success: note.success)
                        .padding(.bottom, HLSpace.xxxl)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .id(note.id)
                }
            }
        }

        // MARK: - Remember-this (COACH-3)

        /// `true` for a user turn on a paired install — only then can the
        /// statement be folded into the server-stored self-context.
        private func canRemember(_ entity: ChatEntity) -> Bool {
            guard backend.hasServer, appContainer != nil else { return false }
            if case .user = entity.role {
                return !entity.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            return false
        }

        private func rememberStatement(_ statement: String) {
            guard let container = appContainer else { return }
            Task {
                let result = await container.coachAboutMeStore.remember(statement)
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                    rememberNote = RememberNote(success: result != nil)
                }
                try? await Task.sleep(for: .seconds(2))
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                    rememberNote = nil
                }
            }
        }

        private func rememberToast(success: Bool) -> some View {
            Label(
                success
                    ? String(localized: "coach.remember.confirmation")
                    : String(localized: "coach.remember.failed"),
                systemImage: success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
            )
            .font(.hlFootnote)
            .foregroundStyle(HLText.primary)
            .padding(.horizontal, HLSpace.md)
            .padding(.vertical, HLSpace.sm)
            // 08-14 — the toast floats over the transcript, so its translucency
            // is exactly the kind Reduce Transparency asks to be swapped for a
            // solid fill. `HLMaterialBackground` is that swap, made once.
            .background(
                HLMaterialBackground(.thinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: HLRadius.button, style: .continuous))
            )
            .overlay(
                RoundedRectangle(cornerRadius: HLRadius.button, style: .continuous)
                    .stroke(
                        (success ? HLColor.statusOK : HLColor.statusBad).opacity(0.25),
                        lineWidth: 1
                    )
            )
        }

        /// Prefill the composer with the chip seed once + focus (honest UI).
        private func applySeedIfNeeded() {
            guard !didApplySeed else { return }
            didApplySeed = true
            let trimmed = seed?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmed.isEmpty, draft.isEmpty, store.chat.isEmpty else { return }
            draft = trimmed
            inputFocused = true
        }

        private var visibleEntries: [ChatEntity] {
            store.chat.filter { entity in
                switch entity.role {
                case .user, .assistant, .assistantToolCall, .assistantToolResponse:
                    true
                case .hidden:
                    false
                }
            }
        }

        /// Plain assistant prose turns — the only role that can carry the
        /// feedback row (tool-call/response rows are never server-persisted
        /// messages).
        private func isAssistant(_ entity: ChatEntity) -> Bool {
            if case .assistant = entity.role { return true }
            return false
        }

        private func submit() async {
            let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !store.isResponding else { return }
            draft = ""
            await store.send(trimmed)
        }
    }

    /// Single message bubble. Role distinction comes from alignment +
    /// surface, not from a brand hue.
    ///
    /// **v0.8.2 monochrome-restore (W3a/A2):** the user bubble was a
    /// deep-purple chrome fill (not the Coach brand-anchor gradient),
    /// reading as stray purple on a monochrome app. It now fills with the
    /// neutral `HLSurface.tertiary` + adaptive `HLText.primary` text
    /// (high contrast in both appearances). Purple stays reserved for the
    /// coin/hero gradient + send affordance only. The assistant bubble
    /// keeps the canonical Dracula surface + white text (always dark).
    private struct CoachMessageBubble: View {
        let entity: ChatEntity

        var body: some View {
            HStack {
                if isUser { Spacer(minLength: HLSpace.xxl) }
                Text(markdownAttributed(entity.content))
                    .font(.hlBody)
                    .foregroundStyle(bubbleForeground)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, HLSpace.md)
                    .padding(.vertical, HLSpace.sm)
                    .background(bubbleBackground)
                    .clipShape(
                        RoundedRectangle(cornerRadius: HLRadius.md, style: .continuous)
                    )
                if !isUser { Spacer(minLength: HLSpace.xxl) }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityPrefix + entity.content)
        }

        private var isUser: Bool {
            if case .user = entity.role { return true }
            return false
        }

        /// User bubble = neutral `HLSurface.tertiary` (adaptive). Assistant
        /// bubble = `surfaceCanonicalDracula` (#282A36, always dark).
        private var bubbleBackground: Color {
            isUser ? HLSurface.tertiary : HLColor.surfaceCanonicalDracula
        }

        /// User text = adaptive `HLText.primary` (high contrast on
        /// tertiary). Assistant text = white on always-dark surface.
        private var bubbleForeground: Color {
            // FW1-C (M6): assistant bubble ink routes through the tokenized
            // AI-hero white (HLColor.aiHeroInk) instead of a raw white literal.
            isUser ? HLText.primary : HLColor.aiHeroInk
        }

        private var accessibilityPrefix: String {
            isUser
                ? String(localized: "You: ")
                : String(localized: "coach.bubble.prefix")
        }

        /// Mirrors SpeziChat's internal markdown parse so the bubble
        /// supports the same inline `**bold**` / `_italic_` / `[link]`
        /// formatting the assistant produces. Falls back to a plain
        /// `AttributedString` if the markdown is malformed.
        private func markdownAttributed(_ raw: String) -> AttributedString {
            let options = AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
            if let attributed = try? AttributedString(markdown: raw, options: options) {
                return attributed
            }
            return AttributedString(stringLiteral: raw)
        }
    }

    /// Three-dot typing indicator. Same dark surface as the assistant
    /// bubble — visually unmistakable as "Coach is composing".
    private struct CoachTypingBubble: View {
        @State private var phase: Int = 0
        /// v0.12 W4-6 — the doc previously CLAIMED this indicator honoured
        /// reduce-motion "automatically"; it did not — the phase loop pulsed
        /// unconditionally. Gate the loop on the live preference: reduce-motion
        /// renders the three dots STATIC (all at the dim opacity) and skips the
        /// loop entirely, so a reduce-motion user sees a calm "Coach is
        /// composing" affordance with no pulse.
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            HStack(spacing: HLSpace.xs) {
                ForEach(0 ..< 3, id: \.self) { index in
                    Circle()
                        .fill(HLColor.aiHeroInk.opacity(dotOpacity(index)))
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, HLSpace.md)
            .padding(.vertical, HLSpace.sm)
            .background(HLColor.surfaceCanonicalDracula)
            .clipShape(RoundedRectangle(cornerRadius: HLRadius.md, style: .continuous))
            .accessibilityLabel(String(localized: "coach.typing.label"))
            .task {
                // Reduce-motion: render static, never advance the phase loop.
                guard !reduceMotion else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    phase = (phase + 1) % 3
                }
            }
        }

        /// Static dim opacity under reduce-motion; the travelling-highlight
        /// pulse otherwise.
        private func dotOpacity(_ index: Int) -> Double {
            if reduceMotion { return 0.35 }
            return phase == index ? 0.9 : 0.35
        }
    }

    /// **Server-parity (v1.4.23 H7 route)** — subtle thumbs-up/down under a
    /// server-persisted assistant reply. Secondary-styled (tertiary ink,
    /// icon-only) so it never competes with the prose; the selected thumb
    /// fills + tints. The server contract is one-shot (409 on a repeat), so
    /// both buttons disable once a rating landed.
    private struct CoachFeedbackRow: View {
        let store: CoachConversationStore
        let entityID: UUID

        var body: some View {
            let rating = store.feedback.rating(forEntity: entityID)
            HStack(spacing: HLSpace.md) {
                thumb(
                    .helpful,
                    symbol: "hand.thumbsup",
                    label: String(localized: "coach.feedback.helpful.label"),
                    current: rating
                )
                thumb(
                    .unhelpful,
                    symbol: "hand.thumbsdown",
                    label: String(localized: "coach.feedback.unhelpful.label"),
                    current: rating
                )
            }
            .padding(.leading, HLSpace.md)
        }

        private func thumb(
            _ value: CoachFeedbackRating,
            symbol: String,
            label: String,
            current: CoachFeedbackRating?
        ) -> some View {
            let isSelected = current == value
            return Button {
                Task { await store.submitFeedback(value, forEntity: entityID) }
            } label: {
                Image(systemName: isSelected ? symbol + ".fill" : symbol)
                    .font(.hlIcon(HLIconSize.sm))
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(HLText.tertiary))
                    // Comfortable tap target around the small glyph without
                    // growing the visual footprint.
                    .padding(HLSpace.xs)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(current != nil || store.feedback.isSubmitting(entityID: entityID))
            .accessibilityLabel(label)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
    }

    /// **v1.18.1 (§3)** — actionable coach cadence-suggestion card. Quiet,
    /// monochrome; renders under the latest reply when the server emitted a
    /// `suggestion` frame. Accept creates a `MeasurementReminder` (origin COACH)
    /// server-side; it then appears in the native list (Settings → Notifications
    /// → Manage reminders).
    private struct CoachSuggestionCard: View {
        let suggestion: CoachServerService.CoachReminderSuggestion
        let onAccept: () -> Void
        let onDismiss: () -> Void
        let onStop: () -> Void

        var body: some View {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                Label(String(localized: "coach.reminderSuggestion.title"), systemImage: "bell.badge")
                    .font(.hlCaption)
                    .foregroundStyle(HLText.secondary)
                Text(cadenceLabel)
                    .font(.hlBody)
                    .foregroundStyle(HLText.primary)
                    .fixedSize(horizontal: false, vertical: true)
                // Canonical HLButton CTAs (44pt-floored, monochrome) — never raw
                // bordered/controlSize(.small), which dropped the hit target below
                // the a11y floor + drifted from every other CTA (QA D-H1/D-M1).
                HStack(spacing: HLSpace.sm) {
                    HLButton(
                        String(localized: "coach.reminderSuggestion.accept"),
                        variant: .primary,
                        size: .compact,
                        action: onAccept
                    )
                    HLButton(
                        String(localized: "coach.reminderSuggestion.dismiss"),
                        variant: .secondary,
                        size: .compact,
                        action: onDismiss
                    )
                }
                HLButton(
                    String(localized: "coach.reminderSuggestion.stop"),
                    variant: .ghost,
                    size: .compact,
                    action: onStop
                )
            }
            .padding(HLSpace.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                HLSurface.secondary,
                in: RoundedRectangle(cornerRadius: HLRadius.md, style: .continuous)
            )
            .accessibilityElement(children: .contain)
        }

        /// Resolve the server-supplied i18n key. `String(localized:)` returns the
        /// key verbatim when the catalog has no entry, so an unknown future
        /// cadence falls back to a generic, still-readable label.
        private var cadenceLabel: String {
            let resolved = String(localized: String.LocalizationValue(suggestion.label))
            return resolved == suggestion.label
                ? String(localized: "coach.reminderSuggestion.generic")
                : resolved
        }
    }

    /// **v1.18.1 (§3)** — quiet confirmation after the user accepts a cadence
    /// suggestion; points at where the new reminder now lives.
    private struct CoachSuggestionAcceptedNote: View {
        var body: some View {
            Label(String(localized: "coach.reminderSuggestion.accepted"), systemImage: "checkmark.circle")
                .font(.hlCaption)
                .foregroundStyle(HLText.secondary)
                .padding(.horizontal, HLSpace.md)
        }
    }

    // `CoachInputRow` (the composer input row + iOS-26 GlassEffectContainer
    // morph) lives in `AskCoachSheet+InputRow.swift`.
    //
    // `CoachProvenanceDisclosure` (CO4 — the collapsed "what I'm looking at"
    // evidence block), `ProvenanceChip`, `CoachTokenFooter` (CO5 — quiet token
    // caption), and the `CoachProvenanceLabels` resolver live in
    // `AskCoachSheet+Provenance.swift` (split out v0154 to keep this file under
    // the 600-line ceiling).
#endif
