import SwiftUI
#if canImport(UIKit)
    import UIKit
#endif

#if canImport(SpeziChat)
    /// Bottom input row of the AskCoach composer — `TextField` + send button.
    /// We own the submit path so the LLM dispatch flows through
    /// `store.send(...)` once, with no SpeziChat double-dispatch guard.
    ///
    /// **iOS-26 morph (W27 / QOL-AUDIT H2):** the field + send button are
    /// wrapped in `HLGlassEffectContainer` and share a `@Namespace`, so they
    /// read as ONE fluid-glass system. The signature iOS-26 behaviour: the
    /// send button *emerges / merges* out of the input capsule when the draft
    /// becomes sendable, and dissolves back into it when the field empties —
    /// the container fuses the two glass shapes during the transition. The
    /// morph is `accessibilityReduceMotion`-gated (instant on/off when motion
    /// is disabled). Monochrome doctrine: the glass is the chrome; the send
    /// button is chrome too — its active state is the monochrome
    /// `HLAccent.primary` (the only sanctioned purple in Coach is the coin
    /// gradient, never this composer control). On iOS
    /// 18-25 the container / IDs are no-ops and we fall back to the prior
    /// `.thinMaterial` row with a `HLSurface.tertiary` field + always-present
    /// (disabled-when-empty) send button — no behaviour change either way.
    struct CoachInputRow: View {
        @Binding var draft: String
        var focused: FocusState<Bool>.Binding
        let isResponding: Bool
        let onSubmit: () -> Void

        @Namespace private var glassNS
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.openURL) private var openURL

        /// Voice dictation (web-parity v1.18.7). Owned here so the mic lives with
        /// the field; transcribes into `$draft`, never auto-sends.
        @State private var dictation = CoachDictationModel()

        var body: some View {
            HLGlassEffectContainer(spacing: HLSpace.sm) {
                HStack(alignment: .bottom, spacing: HLSpace.sm) {
                    // Mic sits left of the field. Hidden when the device has no
                    // recognizer at all; disabled-and-routes-to-Settings when the
                    // user denied permission.
                    if dictation.availability != .unsupported {
                        micButton
                    }
                    field
                    // On iOS 26 the button is conditional so it morphs in / out
                    // of the shared glass system; on the fallback it is always
                    // present (disabled when empty) to keep the layout stable.
                    if showSendButton {
                        sendButton
                            .transition(.opacity)
                    }
                }
            }
            .padding(.horizontal, HLSpace.lg)
            .padding(.top, HLSpace.sm)
            .padding(.bottom, HLSpace.xxs)
            .background(rowBackground)
            // Build 273 — a persistent, visible statement under the composer
            // that the answers are generated, fallible and not medical advice
            // (App Review 1.2 / 5.1.1); the first-launch disclaimer alone is a
            // screen the reviewer may never reopen.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Text("coach.aiGeneratedNote")
                    .font(.hlCaption2)
                    .foregroundStyle(HLText.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, HLSpace.lg)
                    .padding(.bottom, HLSpace.xs)
                    .accessibilityIdentifier("coach.aiGeneratedNote")
            }
            .animation(reduceMotion ? nil : .smooth(duration: 0.28), value: canSend)
            .animation(reduceMotion ? nil : .smooth(duration: 0.28), value: dictation.isRecording)
            // Stop a live session if the coach starts responding (the field is
            // disabled then) so we never keep the mic hot across a send.
            .onChange(of: isResponding) { _, responding in
                if responding { dictation.stop() }
            }
        }

        // MARK: - Mic / dictation

        /// F2 (v0153) — the mic glyph reflects state: a live session shows the
        /// waveform; a denied permission shows the slashed mic (a disabled
        /// affordance that routes to Settings on tap); otherwise the plain mic.
        private var micGlyph: String {
            if dictation.isRecording { return "waveform" }
            if dictation.availability == .denied { return "mic.slash.fill" }
            return "mic.fill"
        }

        /// F2 (v0153) — denied permission reads as a disabled/tertiary tint so
        /// the slashed mic clearly looks unavailable (it still routes to
        /// Settings on tap — that affordance is preserved in `micButton`).
        private var micTint: Color {
            if dictation.isRecording { return HLAccent.primary }
            if dictation.availability == .denied { return HLText.tertiary }
            return HLText.secondary
        }

        private var micButton: some View {
            Button {
                switch dictation.availability {
                case .denied:
                    // Permission was refused — route to Settings rather than
                    // silently no-op on tap.
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                case .available, .unsupported:
                    dictation.toggle(into: $draft)
                }
            } label: {
                Image(systemName: micGlyph)
                    // CO3 (v0154 walkthrough): `HLIconSize.lg` (20pt). C4 (b199)
                    // raised both composer glyphs to `hero` (28pt) to "match
                    // optical weight", but 28pt + glass padding made the pucks
                    // taller than the single-line field — the mic read oversized.
                    // 20pt ("toolbar / prominent inline affordances") lands the
                    // glass circle ≈ the field capsule height; mic == send stays
                    // 1:1 (siblings in the same glass system, `MicChrome` mirrors
                    // `SendChrome`).
                    .font(.hlIcon(HLIconSize.lg))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(micTint)
                    .symbolEffect(
                        .variableColor.iterative,
                        options: reduceMotion ? .nonRepeating : .repeating,
                        isActive: dictation.isRecording
                    )
                    .modifier(MicChrome())
            }
            .hlGlassEffectID("composer-mic", in: glassNS)
            .disabled(isResponding)
            .sensoryFeedback(.impact(weight: .light), trigger: dictation.isRecording)
            .accessibilityLabel(
                dictation.isRecording
                    ? String(localized: "Stop dictation")
                    : String(localized: "Dictate your question")
            )
        }

        // MARK: - Field

        /// Placeholder swaps to a "Listening…" cue while a dictation session is
        /// live so the user gets clear feedback the mic is actively transcribing
        /// (QA-b198 Design-L5).
        private var fieldPrompt: String {
            dictation.isRecording
                ? String(localized: "coach.composer.listening")
                : String(localized: "Ask me something …")
        }

        private var field: some View {
            TextField(
                fieldPrompt,
                text: $draft,
                axis: .vertical
            )
            .lineLimit(1 ... 5)
            .textFieldStyle(.plain)
            .font(.hlBody)
            .foregroundStyle(HLText.primary)
            .padding(.horizontal, HLSpace.md)
            .padding(.vertical, HLSpace.sm)
            .modifier(FieldChrome())
            .hlGlassEffectID("composer-field", in: glassNS)
            .focused(focused)
            .disabled(isResponding)
            .submitLabel(.send)
            .onSubmit(onSubmit)
        }

        // MARK: - Send button

        private var sendButton: some View {
            Button(action: onSubmit) {
                Image(systemName: "arrow.up.circle.fill")
                    // CO3 (v0154 walkthrough): `HLIconSize.lg` (20pt), symmetric
                    // with the mic. Chrome control with a deliberate hit-target
                    // size, not body copy — must not grow with Dynamic Type and
                    // reflow the row.
                    .font(.hlIcon(HLIconSize.lg))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(canSend ? HLAccent.primary : HLText.secondary)
                    // v0.14.x Q — bounce the send glyph the instant the coach
                    // starts responding (the discrete `isResponding` false→true
                    // edge = "message sent"). Keyed on `isResponding` so it
                    // fires once per send, not on every body pass; reduce-motion
                    // gated (the send still works, just without the flourish).
                    .symbolEffect(.bounce, value: reduceMotion ? false : isResponding)
                    .modifier(SendChrome())
            }
            .hlGlassEffectID("composer-send", in: glassNS)
            .disabled(!canSend)
            // M2 (QOL-AUDIT): light impact confirms a sent message. Keyed on
            // the `isResponding` false→true edge so it fires once per send,
            // not on every body pass (matches the `.symbolEffect` trigger).
            .sensoryFeedback(.impact(weight: .light), trigger: isResponding) { _, responding in
                responding
            }
            .accessibilityLabel(String(localized: "Send question"))
        }

        // MARK: - Conditional / fallback plumbing

        /// On iOS 26 the send button only exists while sendable, so the glass
        /// container can morph it in / out of the field. On iOS 18-25 it stays
        /// mounted (disabled when empty) — the IDs are no-ops there, so a
        /// conditional would just pop without the fluid union.
        private var showSendButton: Bool {
            if #available(iOS 26.0, *) {
                canSend
            } else {
                true
            }
        }

        /// iOS 26 fields carry their own glass chrome, so the row backing is
        /// transparent and only the glass shapes float. iOS 18-25 keeps the
        /// prior row, now painted by `HLMaterialBackground` so Reduce
        /// Transparency swaps the translucency for the opaque fill instead of
        /// leaving a see-through composer.
        ///
        /// The transparent iOS-26 branch is safe under the preference because
        /// nothing translucent sits behind it: the composer is a stacked
        /// sibling of the transcript, not a float over it, and the sheet paints
        /// `.presentationBackground(HLColor.surface)`. Both facts are asserted
        /// by `Phase8MaterialCallSiteTests`, so this backing cannot quietly
        /// become wrong under a later layout change.
        @ViewBuilder
        private var rowBackground: some View {
            if #available(iOS 26.0, *) {
                Color.clear
            } else {
                HLMaterialBackground(.thinMaterial)
            }
        }

        private var canSend: Bool {
            !isResponding
                && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        /// Field background: glass capsule on iOS 26, `HLSurface.tertiary`
        /// rounded-rect on the fallback.
        ///
        /// The `fallback:` is named rather than defaulted: 08-04's doctrine is
        /// that Reduce Transparency gets the *same* surface iOS 18-25 has always
        /// shipped, so the opaque answer here has to be `HLSurface.tertiary` —
        /// the helper's `HLColor.backgroundEleva` default would invent a third
        /// appearance for the one cell nobody looks at.
        private struct FieldChrome: ViewModifier {
            func body(content: Content) -> some View {
                if #available(iOS 26.0, *) {
                    content.hlGlassEffect(
                        in: RoundedRectangle(cornerRadius: HLRadius.md, style: .continuous),
                        fallback: HLSurface.tertiary
                    )
                } else {
                    content
                        .background(HLSurface.tertiary)
                        .clipShape(
                            RoundedRectangle(cornerRadius: HLRadius.md, style: .continuous)
                        )
                }
            }
        }

        /// Mic glyph chrome: mirrors `SendChrome` so the dictation control reads
        /// as part of the same fluid-glass system on iOS 26 and a plain glyph on
        /// the fallback.
        ///
        /// `fallback: .clear` is the iOS 18-25 appearance restated: the glyph
        /// carries no backplate there, so the preference must not conjure one.
        private struct MicChrome: ViewModifier {
            func body(content: Content) -> some View {
                if #available(iOS 26.0, *) {
                    content
                        .padding(HLSpace.xs)
                        .hlGlassEffect(in: Circle(), interactive: true, fallback: .clear)
                } else {
                    content
                }
            }
        }

        /// Send glyph chrome: interactive glass circle on iOS 26 (so it
        /// fuses with the field as one system + responds to touch), plain
        /// glyph on the fallback. `fallback: .clear` for the same reason
        /// `MicChrome` names it — the two are one system and must resolve alike.
        private struct SendChrome: ViewModifier {
            func body(content: Content) -> some View {
                if #available(iOS 26.0, *) {
                    content
                        .padding(HLSpace.xs)
                        .hlGlassEffect(in: Circle(), interactive: true, fallback: .clear)
                } else {
                    content
                }
            }
        }
    }
#endif
