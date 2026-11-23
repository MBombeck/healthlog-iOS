import SwiftUI

#if canImport(SpeziChat)
    import SpeziChat
#endif

// MARK: - Custom transcript + input row

// Split out of `AskCoachSheet.swift` to keep that file under the
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
        var seed: String? // One-shot composer seed from a prompt chip
        /// The welcome and the suggestion chips while the
        /// transcript is empty. They live inside the scroll view, so the
        /// composer above the keyboard always keeps its place: at the
        /// accessibility sizes the two are taller than the room the keyboard
        /// leaves, and as a fixed block above the transcript they pushed the
        /// composer under the keyboard (iOS 26.5).
        var emptyHeader: AnyView?
        @State private var draft: String = ""
        @State private var didApplySeed = false
        @FocusState private var inputFocused: Bool
        /// QoL-A2 (Felt-craft #5) — gate the transcript auto-scroll on
        /// reduce-motion (instant jump to tail when motion is disabled).
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        /// Reach the shared about-me store + server gate so a
        /// "remember this" on a user turn folds the statement into the coach
        /// self-context.
        @Environment(\.appContainer) private var appContainer
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
                        // A plain stack, not a lazy one. On iOS
                        // 26.5 at the accessibility sizes the lazy stack kept
                        // re-estimating its rows while the scroll view adjusted
                        // its offset for the bottom anchor (keyboard open, each
                        // streamed token scrolling to the tail), and the main
                        // thread stayed in that layout for 30 s and more
                        // (`LazyStack.measureEstimates`,
                        // `ScrollViewAdjustedState.adjustOffsetIfNeeded` in the
                        // samples). A Coach conversation is a few dozen
                        // bubbles at most; measured once, it lays out exactly.
                        VStack(alignment: .leading, spacing: HLSpace.md) {
                            if let emptyHeader {
                                emptyHeader
                                    .id("coach-empty-header")
                                // The "AI-generated, not medical advice" line
                                // greets a new conversation under the welcome
                                // and leaves with it once the first message
                                // stands (App Review 1.2, 5.1.1, 1.4.1).
                                CoachAIGeneratedNote()
                                    .id("coach-ai-note")
                            }
                            ForEach(visibleEntries) { entity in
                                VStack(alignment: .leading, spacing: HLSpace.xs) {
                                    CoachMessageBubble(entity: entity)
                                        // Long-press a user turn
                                        // to fold the statement into the coach
                                        // self-context (server matches the field).
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
                                    // 1.0.3 (App Review 1.4.1, audit row 7) — the
                                    // citation under EVERY assistant reply, on
                                    // every arm, visible without expanding
                                    // anything. It shares one row with the one
                                    // disclosure (`CoachReplyActions`).
                                    if isAssistant(entity) {
                                        CoachReplyActions(store: store, entityID: entity.id)
                                        // The proposal, under the row.
                                        CoachAnswerExtras(store: store, entityID: entity.id)
                                    }
                                }
                                .id(entity.id)
                            }
                            // v1.18.1 — coach cadence suggestion: an
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
                            // One quiet line while the turn runs.
                            if let line = store.live.statusLine {
                                CoachLiveStatusLine(text: line)
                                    .id("coach-live-status")
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
                    // The transcript fades out above the composer instead of
                    // ending on a hard edge.
                    .mask { CoachTranscriptFade() }
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
                    // The proposal and the trail link arrive after
                    // the answer; bring them up above the keyboard, which stays
                    // open after sending like everywhere else in the chat.
                    // The views they need are inserted in the same pass, so the
                    // scroll waits a moment for them (it ran twice while the stack
                    // was lazy; POLISH-B B1 made it a plain one, the second pass
                    // stays as a harmless safety net).
                    .onChange(of: store.live.settledRevision) { _, _ in
                        Task { @MainActor in
                            // Twice: once the stack has placed the new views,
                            // and again after it has measured them.
                            for delay in [50, 350] {
                                try? await Task.sleep(for: .milliseconds(delay))
                                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                                    proxy.scrollTo("transcript-tail", anchor: .bottom)
                                }
                            }
                        }
                    }
                    // v1.18.1 — bring a freshly-arrived cadence card into view.
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

        // MARK: - Remember-this

        /// `true` for a user turn — only then can the statement be folded into the server-stored self-context.
        private func canRemember(_ entity: ChatEntity) -> Bool {
            guard appContainer != nil else { return false }
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
            // The toast floats over the transcript, so its translucency
            // is exactly the kind Reduce Transparency asks to be swapped for a
            // solid fill. `HLMaterialBackground` is that swap, made once.
            .background(
                // A toast floating over the transcript, not a content card.
                // swiftlint:disable:next hl_no_glass_in_content
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

        /// Plain assistant prose turns — the only role that carries the row
        /// under an answer (tool-call/response rows are never server-persisted
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
            // Assistant bubble ink routes through the tokenized
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
        /// The doc previously CLAIMED this indicator honoured
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

    /// **The one row under an assistant reply.** In front the sources link
    /// (every arm, App Review 1.4.1, never behind a disclosure), behind it one
    /// disclosure for the evidence and the trail when either exists. Where the
    /// line is too narrow, the disclosure moves under the link. The sources
    /// link stays outside the bubble's combined accessibility element.
    private struct CoachReplyActions: View {
        let store: CoachConversationStore
        let entityID: UUID
        @State private var expanded = false

        var body: some View {
            let provenance = store.provenanceByEntity[entityID].flatMap { envelope in
                CoachProvenanceBody.hasContent(envelope) ? envelope : nil
            }
            let hasTrail = store.live.hasTrail(entityID)
            let canExpand = provenance != nil || hasTrail
            VStack(alignment: .leading, spacing: HLSpace.xs) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: HLSpace.md) {
                        HLSourcesLink(topic: .aiAssistant)
                        Spacer(minLength: 0)
                        if canExpand { disclosure }
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        HLSourcesLink(topic: .aiAssistant)
                        if canExpand { disclosure }
                    }
                }
                if expanded, canExpand {
                    CoachAnswerDetails(
                        store: store,
                        entityID: entityID,
                        provenance: provenance,
                        showsTrail: hasTrail
                    )
                    .transition(.opacity)
                }
            }
            .padding(.leading, HLSpace.md)
        }

        private var disclosure: some View {
            CoachAnswerDisclosureToggle(expanded: $expanded, onExpand: loadTrailIfNeeded)
        }

        /// The steps load on the first opening, and again after a failure.
        /// Evidence alone needs no request.
        private func loadTrailIfNeeded() {
            guard store.live.hasTrail(entityID) else { return }
            let trail = store.live.trails[entityID]
            if trail == nil || trail == .failed {
                Task { await store.loadTrail(for: entityID) }
            }
        }
    }

    /// **v1.18.1** — actionable coach cadence-suggestion card. Quiet,
    /// monochrome; renders under the latest reply when the server emitted a
    /// `suggestion` frame. Accept creates a `MeasurementReminder` (origin COACH)
    /// server-side; it then appears in the native list (Settings → Notifications
    /// → Manage reminders).
    private struct CoachSuggestionCard: View {
        let suggestion: CoachServerService.CoachReminderSuggestion
        let onAccept: () -> Void
        let onDismiss: () -> Void
        let onStop: () -> Void

        /// Outlined like the Coach's other offers in the transcript.
        var body: some View {
            HLCard(style: .outline) {
                content
            }
            .accessibilityElement(children: .contain)
        }

        private var content: some View {
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
                HLButtonPair {
                    HLButton("coach.reminderSuggestion.accept", variant: .primary, action: onAccept)
                } secondary: {
                    HLButton("coach.reminderSuggestion.dismiss", variant: .secondary, action: onDismiss)
                }
                HLLinkButton("coach.reminderSuggestion.stop", action: onStop)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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

    /// **v1.18.1** — quiet confirmation after the user accepts a cadence
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
    // `CoachProvenanceBody` (CO4 — the evidence the row's disclosure opens),
    // `ProvenanceChip` and the `CoachProvenanceLabels` resolver live in
    // `AskCoachSheet+Provenance.swift` (split out v0154 to keep this file under
    // the 600-line ceiling).
#endif
