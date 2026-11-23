import SwiftUI

#if canImport(SpeziChat)
    import SpeziChat
#endif

/// **POLISH-COACH → v0.5.7 G.3** — `.large`-detent sheet
/// presented from the `AskCoachHeroCard` on the Insights tab.
///
/// **G.3 status:** the v0.5.6 "Bald verfügbar" panel is gone — the
/// sheet now hosts a real conversational surface backed by
/// `CoachConversationStore` → `LocalLLMService.respond(prompt:)` →
/// Apple FoundationModels. The visual recipe stays close to the v0.5.6
/// welcome panel for surfaces that are still empty (no turns yet), but
/// once the user sends their first prompt the `SpeziChat.ChatView`
/// takes over the body region.
///
/// **Surface composition:**
/// 1. Welcome lockup + suggestion chips ride above the chat only while
///    `store.chat.isEmpty`; once a turn lands they disappear so the full sheet
///    height belongs to the transcript.
/// 2. `SpeziChat.ChatView($store.chat)` paints the transcript + text-input row
///    with a typing-indicator wired to `store.isResponding`.
/// 3. The kill-card surfaces when `service.availability != .available`
///    (Apple-Intelligence-off / model-not-ready / device-ineligible) — the
///    user never reaches a broken send path.
///
/// **Why suggestion chips drive `store.send(...)` directly (not the text
/// field):** the chips are pre-validated entry prompts — tapping fires the
/// conversation immediately rather than priming an editable draft (Apple
/// Messages' "smart reply" contract). The text field is the open-ended path.
///
/// **Reduce-motion:** the typing indicator (`CoachTypingBubble`) explicitly
/// gates its three-dot phase loop on `accessibilityReduceMotion` — when the
/// preference is on the dots render static and the loop never runs (v0.12 W4-6;
/// the prior "honours it automatically" claim was untrue and is corrected).
///
/// **G.4 hand-off:** health-context wiring happens on the
/// `CoachConversationStore.send(_:)` path before the LocalLLMService call.
struct AskCoachSheet: View {
    /// Optional composer seed from an Insights prompt chip; pre-fills
    /// the composer (editable, not auto-sent). `nil` for coin / hero-tap entries.
    var seed: String?
    /// **A360 H1/H2** — optional metric/correlation scope from the launch
    /// site (per-tile "Ask the coach about this", per-metric page, mood page,
    /// correlation card). Seeded onto the store on appear so the FIRST server turn
    /// of a fresh conversation carries the wire `scope` ({ sources, window }) — the
    /// coach then knows which metric the user was looking at. `nil` for the generic
    /// FAB / hero / deep-link entries (default all-source snapshot).
    var launchScope: CoachLaunchScope?
    /// Non-private so the `+ServerFallback` extension's `coachConsentSheet`
    /// can reach the container.
    @Environment(\.appContainer) var appContainer
    /// The AI-consent sheet is presented as a NESTED sheet on the
    /// Coach surface itself (local state) — see `coachConsentSheet` in
    /// `+ServerFallback`. Routing through the shell-owned `explicitPromptToken`
    /// could not present over the already-presented Coach sheet.
    @State var showCoachConsentSheet = false
    /// C2 (b199 walkthrough) — drives the push to the existing
    /// `CoachConversationsScreen` history list from the Coach sheet's overflow
    /// menu (previously only reachable via Settings → Coach → Past conversations).
    @State private var showPastConversations = false
    /// The "External AI needs a server provider" step, presented when
    /// the user picks External AI but no server provider is configured (so the
    /// consent grant would be a noop and the chooser would silently bounce). It
    /// routes the user to Settings → Assistant to set one up. Non-private so the
    /// `+ServerFallback` extension can flip it from the consent-accept guard +
    /// the chooser CTA. See `coachProviderNeededSheet`.
    @State var showCoachProviderNeeded = false
    /// Used by `coachProviderNeededSheet` to route the operator to
    /// Settings → Assistant. Non-private so the `+ServerFallback` extension can
    /// reach it.
    @Environment(AppRouter.self) var appRouter
    @Environment(\.dismiss) var dismissCoachSheet

    var body: some View {
        // A sheet that only shows something: the close button. The overflow
        // menu stays an ordinary bar item on the content.
        HLSheetScaffold("Ask the coach") {
            content
                // C2 (b199 walkthrough) — the full history list
                // (`CoachConversationsScreen`) already exists but was only
                // reachable via Settings → Coach → Past conversations. Surface it
                // directly from the chat: an overflow menu now carries both "New
                // conversation" (the prior reset action) and "Past conversations"
                // (pushes the existing, tested screen).
                .navigationDestination(isPresented: $showPastConversations) {
                    CoachConversationsScreen()
                }
                .hlPageActions([
                    .more(label: "Coach options") {
                        Button("New conversation", systemImage: "arrow.counterclockwise") {
                            appContainer?.coachConversationStore.reset()
                        }
                        .disabled(appContainer == nil)
                        Button("coach.toolbar.pastConversations", systemImage: "clock.arrow.circlepath") {
                            showPastConversations = true
                        }
                        .disabled(appContainer == nil)
                    }
                ])
        }
        // Pre-warm the hoisted on-device session as the sheet
        // appears so the first turn doesn't pay a visible cold-start. No-op on
        // every runtime where the model isn't `.available` (AI off,
        // model downloading, device ineligible) — `prewarm()` self-guards.
        .onAppear {
            appContainer?.coachConversationStore.service.prewarm()
            // A360 H1/H2 — hand the launch scope to the store so the first server
            // turn of a fresh conversation narrows the snapshot to the metric/
            // correlation the user was looking at. `nil` (generic FAB / hero /
            // deep-link entry) clears any stale scope from a prior scoped open.
            appContainer?.coachConversationStore.setLaunchScope(launchScope)
            // Opening the Coach (from the FAB or the More-tab row) marks
            // it seen: clears the unread dot optimistically + stamps the server so
            // the cleared state follows the user across devices. Single entry point
            // for every Coach surface (FAB / More / Insights chip).
            appContainer?.coachNudgeStore.markSeenOptimistically()
        }
        // Tear down an in-flight Coach turn when the sheet is dismissed
        // mid-stream. Without this the server SSE turn ran to its full
        // 120s-idle / 600s-ceiling budget, held the connection, wasted the
        // health-context egress the user tried to abort, and on completion mutated
        // + persisted a gone view's store. `cancelInFlightTurn()` cancels the held
        // task → `URLSession` cooperative cancellation tears the socket down and
        // the turn runners bail on `Task.isCancelled` before persisting.
        .onDisappear {
            appContainer?.coachConversationStore.cancelInFlightTurn()
        }
        // Nested AI-consent sheet (see `coachConsentSheet` in
        // `+ServerFallback`), presented OVER the Coach sheet from this view's own
        // hierarchy because the shell can't present over an already-presented
        // sheet — the recurring "consent does nothing until app restart" bug.
        .sheet(isPresented: $showCoachConsentSheet) { coachConsentSheet }
        // The "External AI needs a server provider" step. Presented
        // when the user picks External AI without a configured provider, so the
        // dead-end (silent bounce to the chooser) becomes an actionable route to
        // Settings → Assistant. Lives in `+ServerFallback`.
        .sheet(isPresented: $showCoachProviderNeeded) { coachProviderNeededSheet }
    }

    /// Top-level content branch — splits the available kill-card path
    /// out from the live conversation path so the unavailable banner
    /// has its own breathing room and the SpeziChat surface doesn't
    /// have to know about availability.
    @ViewBuilder private var content: some View {
        if let container = appContainer {
            let store = container.coachConversationStore
            // v0.14.7 COACH-redesign — anchor Observation on `revision`: aiMode is
            // computed from untracked UserDefaults + Keychain, so this read is what
            // re-routes the surface live on a mode flip (else only on restart).
            // swiftlint:disable:next redundant_discardable_let
            let _ = container.aiConsentStore.revision
            // On-device available → on-device
            // conversation. Otherwise, if the server fallback is wired +
            // consented, run the server-backed conversation instead of
            // the kill-card. If the fallback is available but consent is
            // pending, surface a consent CTA. Only when neither path can
            // run do we fall back to the legacy unavailable surfaces.
            if let blocked = Self.coachEntryRefusal(container.aiCapabilityGate) {
                // A decision (operator, record, module, the person's
                // own switch) closed the Coach: say which, offer nothing to send.
                unavailableSurface(
                    title: String(localized: "Coach unavailable"),
                    message: Self.coachRefusalCopy(blocked)
                )
            } else if store.shouldUseBYO {
                // The user chose "Own key": run the conversation
                // through their provider directly, regardless of on-device
                // capability.
                conversationSurface(store: store)
            } else if store.shouldUseServerFallback {
                conversationSurface(store: store) // Explicit-pick server arm BEFORE on-device
            } else if store.serverFallbackNeedsConsent {
                // When the device CAN answer on-device but the user
                // picked External AI, offer a real on-device-vs-server CHOICE
                // (`isReady` is true exactly then) instead of the old copy that
                // falsely claimed the iPhone had no on-device Coach. On-device pick
                // flips the mode back so `content` re-renders into the private path.
                serverConsentSurface(
                    container: container,
                    onDeviceCapable: store.service.isReady,
                    // Gate the External AI path on a real provider so
                    // the chooser can mark it unavailable + route to setup instead
                    // of opening a consent sheet that noops + silently bounces.
                    // The server/admin-managed case has NO
                    // per-user provider yet IS serveable; treat it as a present
                    // provider so the consent path (not "set up a provider") runs.
                    hasServerProvider: container.aiProviderStore.config?.isServerAIAvailable == true,
                    onRequestServerConsent: { showCoachConsentSheet = true },
                    onChooseOnDevice: {
                        container.aiConsentStore.setMode(
                            .onDevice,
                            activeProvider: container.aiProviderStore.config?.resolvedProvider ?? .unconfigured,
                            requestOnlineConsent: false
                        )
                    },
                    onNeedsProvider: { showCoachProviderNeeded = true }
                )
            } else if store.service.availability == .available {
                conversationSurface(store: store)
            } else {
                onDeviceUnavailableSurface(availability: store.service.availability)
            }
        } else {
            // No container resolved — happens in #Preview / non-app
            // hosts (test renderers etc.). Show the welcome lockup
            // without the chat surface so the view still composes.
            previewFallback
        }
    }

    // MARK: - Conversation surface

    /// Live conversation surface composed of the welcome lockup (only
    /// while the transcript is empty) + the SpeziChat `ChatView`
    /// bound to `store.chat`.
    private func conversationSurface(store: CoachConversationStore) -> some View {
        VStack(spacing: 0) {
            // CO1 (v0154 walkthrough) — the per-turn active-arm pill (W1-C1's
            // egress-warn capsule) is gone. The operator deliberately picked
            // External AI and flagged the permanent "Answers come from your
            // server" banner over every turn as noise; the web shows no per-turn
            // arm banner either. The honest, on-demand provenance is the collapsed
            // "what I'm looking at" disclosure under each server-arm reply,
            // and the calm empty-state on-device note (`privateProvenanceNote`)
            // still names the private path before the first turn.
            // The welcome and the chips scroll with the
            // transcript (`CoachTranscriptView.emptyHeader`). Above it, outside
            // any scroll view, they were a fixed block: at the accessibility
            // sizes taller than the room above the keyboard, so on iOS 26.5 the
            // composer and its send button ended up under the keyboard.
            chatView(store: store)
        }
        // The `usingServerFallback` / `usingBYO` store flags still gate other
        // behaviour (BYO feedback-row suppression, the empty-state note, the
        // provenance/token footers), so the seed stays — it just no longer paints
        // a pill.
        .onAppear { store.seedIntendedArm() }
    }

    /// Welcome lockup + suggestion chips. Mirrors the v0.5.6 placeholder
    /// composition so the entry-point feel stays consistent — the
    /// operator brief was "Apple-Award restraint", not "rebuild the
    /// welcome each release".
    private func emptyStateHeader(store: CoachConversationStore) -> some View {
        VStack(alignment: .leading, spacing: HLSpace.xl) {
            // When the on-device arm is answering (the
            // private path: no server fallback, no BYO), name the privacy
            // guarantee plainly in the empty state so the first-time user — and
            // especially the privacy-first `aiMode == .none` user who can now
            // reach the coach on a capable device — knows the answer never leaves
            // the iPhone. It is the welcome's one subtitle now; the
            // generic "ask me about your data" line it stood under is gone.
            welcomeLockup(privateNote: !store.usingServerFallback && !store.usingBYO)
            suggestionChipsSection(store: store)
        }
    }

    /// The welcome. Its one subtitle is the on-device privacy note (v0151
    /// ON-DEVICE-REACH), shown only when that arm answers; the chips and the
    /// composer say the rest.
    var welcomeLockup: some View {
        welcomeLockup(privateNote: false)
    }

    /// The Coach's one head form, shared with the onboarding and the source
    /// choice: the empty-state lockup.
    func welcomeLockup(privateNote: Bool) -> some View {
        HLEmptyState(
            icon: "sparkles",
            title: Text(String(localized: "Hi! What would you like to know today?")),
            message: privateNote
                ? Text(String(localized: "Answered privately on your iPhone. Your data never leaves the device."))
                : nil
        )
        .accessibilityElement(children: .combine)
    }

    private func suggestionChipsSection(store: CoachConversationStore) -> some View {
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            HLSectionHeader("Suggestions")
            ForEach(AskCoachSuggestion.defaults, id: \.text) { suggestion in
                AskCoachSuggestionChip(
                    text: suggestion.text,
                    icon: suggestion.icon
                ) {
                    Task { await store.send(suggestion.text) }
                }
            }
        }
        // The header keeps its 24 and 8 pt in this stack.
        .hlContainerGap(HLSpace.sm)
    }

    // MARK: - Custom transcript surface

    /// Replaced the SpeziChat `ChatView`
    /// with a custom transcript so the user-bubble can match the
    /// assistant-bubble visual recipe (operator brief:
    /// "genau so wie das, was der Coach antwortet"). The previous fix
    /// pinned a deep-purple tint on `ChatView`, but
    /// `SpeziChat.MessageStyleModifier` paints the user-bubble with the
    /// asset-catalog `Color.accentColor` literal — that resolves
    /// statically from `Assets.xcassets/AccentColor`, **not** from the
    /// environment `.tint`. The bubble therefore kept the muted
    /// off-grey accent while the white text was hardcoded —
    /// white-on-light-grey, unreadable. By rendering the transcript
    /// ourselves we get full control of both bubble surfaces and
    /// guarantee the user-bubble reads with the same dark-bubble +
    /// white-text contrast the assistant card already lands.
    @ViewBuilder
    private func chatView(store: CoachConversationStore) -> some View {
        #if canImport(SpeziChat)
            CoachTranscriptView(
                store: store,
                seed: seed,
                emptyHeader: isTranscriptEmpty(store: store)
                    ? AnyView(emptyStateHeader(store: store).padding(.top, HLSpace.sm).padding(.bottom, HLSpace.xs))
                    : nil
            )
            .overlay(alignment: .top) {
                if let error = store.lastError {
                    errorBanner(error)
                        .padding(.horizontal, HLSpace.lg)
                        .padding(.top, HLSpace.sm)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        #else
            VStack(spacing: HLSpace.md) {
                Spacer()
                Text(String(localized: "Coach requires Apple Intelligence"))
                    .font(.hlHeadline)
                    .foregroundStyle(HLText.primary)
                Spacer()
            }
        #endif
    }

    /// Inline error banner. Shows on top of the chat surface when the
    /// LocalLLMService throws mid-flow. Tap-to-dismiss.
    private func errorBanner(_ error: LocalLLMError) -> some View {
        HStack(spacing: HLSpace.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.hlIcon(HLIconSize.sm))
                .foregroundStyle(HLColor.statusBad)
            Text(errorCopy(error))
                .font(.hlFootnote)
                .foregroundStyle(HLText.primary)
                .lineLimit(2)
        }
        .padding(.horizontal, HLSpace.md)
        .padding(.vertical, HLSpace.sm)
        // The banner sits on top of the chat surface; under Reduce
        // Transparency the shared seam paints it solid instead of letting the
        // transcript read through an error message.
        .background(
            // A transient banner floating over the chat, not a content card;
            // ErrorBanner speaks HLError, this one the on-device model's error.
            // swiftlint:disable:next hl_no_glass_in_content
            HLMaterialBackground(.thinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: HLRadius.button, style: .continuous))
        )
        .overlay(
            RoundedRectangle(cornerRadius: HLRadius.button, style: .continuous)
                .stroke(HLColor.statusBad.opacity(0.25), lineWidth: 1)
        )
    }

    // `errorCopy(_:)` + `byoErrorCopy(_:)` live in
    // `AskCoachSheet+ServerFallback.swift` (split out v0.13 W4 to keep this file
    // under the 600-line ceiling).

    // MARK: - Unavailable surface (kill-card)

    func unavailableSurface(title: String, message: String) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HLSpace.xl) {
                welcomeLockupReadOnly
                // The title is already final text; the lookup finds nothing
                // and shows it as it is.
                HLCard(LocalizedStringKey(title), style: .outline) {
                    Text(message)
                        .font(.hlSubhead)
                        .foregroundStyle(HLText.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: HLSpace.xxxl)
            }
            .padding(.horizontal, HLSpace.lg)
            .padding(.top, HLSpace.lg)
        }
    }

    /// Welcome lockup variant used inside the unavailable surface — no
    /// suggestion chips (they'd be unfireable) and no tap targets.
    private var welcomeLockupReadOnly: some View {
        welcomeLockup
    }

    // MARK: - Preview fallback

    /// Empty placeholder rendered in `#Preview` / non-app hosts where
    /// `appContainer` is `nil`. Keeps the sheet composable without
    /// standing up a full container in the preview.
    private var previewFallback: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HLSpace.xl) {
                welcomeLockup
                Spacer(minLength: HLSpace.xxxl)
            }
            .padding(.horizontal, HLSpace.lg)
            .padding(.top, HLSpace.lg)
        }
    }

    // MARK: - Helpers

    /// A localized composer opener referencing a specific
    /// metric, used by the per-tile / per-metric "Ask the coach about this"
    /// launch sites so the composer pre-fills with a metric-specific question
    /// instead of opening blank. Plain prose (the chat route is EN/DE-gated and
    /// treats it as composer seed text), matching the existing suggestion-chip
    /// convention. The `%@` carries the localized metric title.
    static func metricSeed(for kind: MetricKind) -> String {
        let title = String(localized: kind.descriptor.title)
        return String(
            format: String(localized: "What does my %@ trend tell me?"),
            title
        )
    }

    /// A localized composer opener for the mood page coach.
    /// Mood has no `MetricKind` title (it is a special Insights surface), so it
    /// gets its own fixed opener.
    static var moodSeed: String {
        String(localized: "What does my mood pattern tell me?")
    }

    /// Treat the transcript as empty for layout purposes when there
    /// are no visible user/assistant turns. This is a single source of
    /// truth so the welcome lockup gates uniformly on the SpeziChat
    /// link state.
    private func isTranscriptEmpty(store: CoachConversationStore) -> Bool {
        #if canImport(SpeziChat)
            return store.chat.isEmpty
        #else
            return store.chat.isEmpty
        #endif
    }
}

// MARK: - Suggestion model

/// Default suggestions surfaced under the welcome lockup. **v0.5.7 G.3**
/// keeps the operator-locked three-prompt set from POLISH-COACH so the
/// existing test contract still passes. G.4 may rewrite these from the
/// user's actual top-of-mind metrics (server-derived) once the
/// privacy-first prompt builder lands.
struct AskCoachSuggestion {
    let text: String
    let icon: String

    static let defaults: [AskCoachSuggestion] = [
        AskCoachSuggestion(
            text: String(localized: "What does my blood pressure mean?"),
            icon: "waveform.path.ecg"
        ),
        AskCoachSuggestion(
            text: String(localized: "How is my sleep?"),
            icon: "moon.zzz.fill"
        ),
        AskCoachSuggestion(
            text: String(localized: "Am I active enough today?"),
            icon: "figure.walk"
        )
    ]
}

#Preview("AskCoachSheet") {
    Color.clear.sheet(isPresented: .constant(true)) {
        AskCoachSheet()
    }
}

// The custom transcript surface (`CoachTranscriptView`, `CoachMessageBubble`,
// `CoachTypingBubble`) lives in `AskCoachSheet+Transcript.swift`; `CoachInputRow`
// (the composer input row + iOS-26 GlassEffectContainer morph) lives in
// `AskCoachSheet+InputRow.swift`. Both split out v0.14.1 to keep this file under
// the 600-line ceiling after the External-AI consent dead-end fix.
