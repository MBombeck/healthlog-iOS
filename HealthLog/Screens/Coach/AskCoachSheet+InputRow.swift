import SwiftUI
#if canImport(UIKit)
    import UIKit
#endif

#if canImport(SpeziChat)
    /// The AskCoach composer: one quiet container with the field in front and
    /// the mic and the send button behind it, as in Messages. We own the
    /// submit path so the LLM dispatch flows through `store.send(...)` once.
    ///
    /// The mic and the send button are circles of one size
    /// (``CoachComposerDisc``). Send only stands there while there is
    /// something to send; without text the mic takes the edge.
    struct CoachInputRow: View {
        @Binding var draft: String
        var focused: FocusState<Bool>.Binding
        let isResponding: Bool
        let onSubmit: () -> Void

        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.openURL) private var openURL
        @Environment(\.dynamicTypeSize) private var dynamicTypeSize

        /// Voice dictation (web-parity v1.18.7). Owned here so the mic lives with
        /// the field; transcribes into `$draft`, never auto-sends.
        @State private var dictation = CoachDictationModel()

        /// How long a dictation hint stays without a new tap or keystroke.
        private static let hintLifetime: Duration = .seconds(8)

        /// The field's font at the current text size, for where the centre of
        /// its last line sits above the baseline.
        private var bodyFont: UIFont {
            UIFont.preferredFont(
                forTextStyle: .body,
                compatibleWith: UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(dynamicTypeSize))
            )
        }

        private var showsSend: Bool {
            CoachComposerRules.showsSend(draft: draft, isResponding: isResponding)
        }

        var body: some View {
            container
                .padding(.horizontal, HLLayout.pageMargin)
                .padding(.top, HLSpace.xs)
                .padding(.bottom, HLSpace.sm)
                .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: dictation.hint)
                .animation(reduceMotion ? .easeOut(duration: 0.15) : .snappy(duration: 0.22), value: showsSend)
                // Stop a live session if the coach starts responding (the field is
                // disabled then) so we never keep the mic hot across a send.
                .onChange(of: isResponding) { _, responding in
                    if responding { dictation.stop() }
                }
                .onChange(of: draft) { _, _ in
                    if !dictation.isActive { dictation.clearHint() }
                }
                .onChange(of: focused.wrappedValue) { _, isFocused in
                    if isFocused { dictation.clearHint() }
                }
                .onChange(of: dictation.hint) { _, hint in
                    if let hint { AccessibilityNotification.Announcement(hint.text).post() }
                }
                .task(id: dictation.hint) {
                    guard dictation.hint != nil else { return }
                    try? await Task.sleep(for: Self.hintLifetime)
                    if !Task.isCancelled { dictation.clearHint() }
                }
        }

        // MARK: - Container

        /// One row in one rounded rect: the field in front, the mic and send
        /// behind it. A dictation hint takes its own line above the row,
        /// inside the same surface.
        private var container: some View {
            let shape = RoundedRectangle(cornerRadius: HLRadius.md, style: .continuous)
            let font = bodyFont
            let line = CoachComposerMetrics.Line(
                isEmpty: draft.isEmpty,
                ascender: font.ascender,
                descender: font.descender,
                lineHeight: font.lineHeight
            )
            return VStack(alignment: .leading, spacing: 0) {
                if let hint = dictation.hint {
                    CoachDictationHintLine(hint: hint)
                        .padding(.horizontal, HLSpace.lg)
                        .padding(.top, HLSpace.md)
                        .transition(.opacity)
                }
                // The circles' centre meets the centre of the field's last
                // line: one line sits on their middle, more lines grow
                // upwards and the circles stay at the last one, as in
                // Messages.
                HStack(alignment: .composerLine, spacing: HLSpace.xs) {
                    field
                        .alignmentGuide(.composerLine) { [line] dimensions in
                            line.lastLineCentre(
                                height: dimensions.height,
                                centre: dimensions[VerticalAlignment.center],
                                lastBaseline: dimensions[.lastTextBaseline]
                            )
                        }
                    buttons
                }
                .padding(.leading, HLSpace.lg)
                // The tap area reaches `HLSpace.xs` past the circle on every
                // side, so the circle stands `CoachComposerMetrics.discInset`
                // from the top, the bottom and the trailing edge.
                .padding([.top, .bottom, .trailing], CoachComposerMetrics.discInset - HLSpace.xs)
            }
            .background {
                shape.fill(HLSurface.secondary)
                shape.strokeBorder(HLColor.separator, lineWidth: HLCardSurface.hairlineWidth)
            }
            .contentShape(shape)
            // The transcript gives way first: at the accessibility sizes a
            // hint and three lines of text would otherwise be squeezed.
            .fixedSize(horizontal: false, vertical: true)
            // A tap on the empty part of the container goes to the field, as
            // it would on one big text box.
            .onTapGesture { focused.wrappedValue = true }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("coach.composer")
        }

        /// The mic and send side by side. The tap areas touch, so the circles
        /// stand `2 × HLSpace.xs` apart.
        private var buttons: some View {
            HStack(spacing: 0) {
                if dictation.availability != .unsupported {
                    micButton
                }
                if showsSend {
                    sendButton
                        .transition(
                            reduceMotion
                                ? .opacity
                                : .scale(scale: 0.6).combined(with: .opacity)
                        )
                }
            }
        }

        // MARK: - Field

        /// Placeholder swaps to a "Listening…" cue while a dictation session is
        /// live so the user gets clear feedback the mic is transcribing.
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
            // At the accessibility sizes six lines and a hint left no room
            // above the keyboard; three lines still show what was dictated.
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 1 ... 3 : 1 ... 6)
            .textFieldStyle(.plain)
            .font(.hlBody)
            .foregroundStyle(HLText.primary)
            .focused(focused)
            .disabled(isResponding)
            .submitLabel(.send)
            .onSubmit(onSubmit)
            .accessibilityIdentifier("coach.composer.field")
        }

        // MARK: - Mic

        /// A live session shows the waveform, a refused permission the slashed
        /// mic (routes to Settings on tap), otherwise the plain mic.
        private var micGlyph: String {
            if dictation.isRecording { return "waveform" }
            if dictation.availability == .denied { return "mic.slash.fill" }
            return "mic.fill"
        }

        private var micButton: some View {
            Button {
                switch dictation.availability {
                case .denied:
                    // Permission was refused: route to Settings rather than
                    // silently no-op on tap.
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                case .available, .unsupported:
                    dictation.toggle(into: $draft)
                }
            } label: {
                CoachComposerDisc(
                    systemImage: micGlyph,
                    style: CoachComposerRules.micStyle(isActive: dictation.isActive)
                )
                .modifier(CoachMicPulse(isOn: dictation.isActive && !reduceMotion))
            }
            .buttonStyle(.plain)
            .disabled(isResponding)
            .sensoryFeedback(.impact(weight: .light), trigger: dictation.isActive)
            .accessibilityLabel(
                dictation.isActive
                    ? String(localized: "Stop dictation")
                    : String(localized: "Dictate your question")
            )
            .accessibilityIdentifier("coach.composer.mic")
        }

        // MARK: - Send

        private var sendButton: some View {
            Button(action: onSubmit) {
                CoachComposerDisc(systemImage: "arrow.up", style: CoachComposerRules.sendStyle)
            }
            .buttonStyle(.plain)
            .disabled(!CoachComposerRules.canSend(draft: draft, isResponding: isResponding))
            // Light impact confirms a sent message, once per send.
            .sensoryFeedback(.impact(weight: .light), trigger: isResponding) { _, responding in
                responding
            }
            .accessibilityLabel(String(localized: "Send question"))
            .accessibilityIdentifier("coach.composer.send")
        }
    }

    /// Where the field and the circles meet in the row.
    enum CoachComposerMetrics {
        /// Space between a circle and the container's top, bottom and
        /// trailing edge.
        static let discInset: CGFloat = HLSpace.sm

        /// How far the middle of a line's glyph box sits above its baseline
        /// (`descender` is negative, as UIKit gives it).
        nonisolated static func lineCentreAboveBaseline(ascender: CGFloat, descender: CGFloat) -> CGFloat {
            (ascender + descender) / 2
        }

        /// The field's font and state, enough to find its last line.
        nonisolated struct Line: Equatable, Sendable {
            let isEmpty: Bool
            let ascender: CGFloat
            let descender: CGFloat
            let lineHeight: CGFloat

            /// The centre of the field's last visible line. An empty field
            /// shows its prompt, which gives no baseline; its one line sits on
            /// the middle. A field scrolled past its line limit reports the
            /// baseline of a line further up, so the bottom line is taken
            /// from the frame.
            func lastLineCentre(height: CGFloat, centre: CGFloat, lastBaseline: CGFloat) -> CGFloat {
                if isEmpty { return centre }
                let baseline = height - lastBaseline > lineHeight ? height + descender : lastBaseline
                return baseline - CoachComposerMetrics.lineCentreAboveBaseline(ascender: ascender, descender: descender)
            }
        }
    }

    extension VerticalAlignment {
        /// The centre of the field's last line and of the composer's circles.
        private enum ComposerLine: AlignmentID {
            static func defaultValue(in context: ViewDimensions) -> CGFloat {
                context[VerticalAlignment.center]
            }
        }

        static let composerLine = VerticalAlignment(ComposerLine.self)
    }

    /// The rules of the composer's buttons, apart from the view so they can
    /// be tested.
    enum CoachComposerRules {
        static func canSend(draft: String, isResponding: Bool) -> Bool {
            !isResponding && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        /// Send stands in the row while there is text, and stays (dimmed) while
        /// the coach answers the question it just sent.
        static func showsSend(draft: String, isResponding: Bool) -> Bool {
            isResponding || !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        static func micStyle(isActive: Bool) -> CoachComposerDisc.Style {
            isActive ? .accent : .quiet
        }

        static let sendStyle: CoachComposerDisc.Style = .accent
    }

    /// The one shape both composer buttons share: a 36 pt circle in a 44 pt
    /// tap area, with one glyph size and weight. A disabled button keeps its
    /// circle and draws it dimmed, so the row never changes its rhythm.
    struct CoachComposerDisc: View {
        enum Style: Equatable {
            /// A quiet circle in the system fill with the primary ink: the
            /// mic at rest.
            case quiet
            /// The accent circle with the contrast ink: send, a starting or
            /// live mic.
            case accent
        }

        /// The visible circle inside the 44 pt tap area.
        static let diameter: CGFloat = HLHitTarget.minimum - 2 * HLSpace.xs

        let systemImage: String
        let style: Style

        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            Image(systemName: systemImage)
                .font(.hlIcon(HLIconSize.lg, weight: .semibold))
                .foregroundStyle(ink)
                .frame(width: Self.diameter, height: Self.diameter)
                .background { disc }
                .frame(width: HLHitTarget.minimum, height: HLHitTarget.minimum)
                .contentShape(Circle())
        }

        private var ink: Color {
            switch (style, isEnabled) {
            case (.accent, true): HLSurface.primary
            case (.quiet, true): HLText.primary
            case (_, false): HLText.tertiary
            }
        }

        /// The quiet circle is the system fill for small controls laid on the
        /// container surface: a recessed surface token reads as almost nothing
        /// on the container in dark (1.15:1), this one as a clear circle in
        /// both appearances. Drawn on the container's own surface so it stays
        /// opaque and looks the same wherever the row sits.
        @ViewBuilder private var disc: some View {
            switch (style, isEnabled) {
            case (.accent, true):
                Circle().fill(HLAccent.primary)
            case (.quiet, _), (.accent, false):
                ZStack {
                    Circle().fill(HLSurface.secondary)
                    Circle().fill(Self.quietFill)
                }
            }
        }

        private static let quietFill = Color(uiColor: .secondarySystemFill)
    }

    /// A slow breath on the live mic, so a running dictation is seen without
    /// a busy animation. Off with Reduce Motion.
    private struct CoachMicPulse: ViewModifier {
        let isOn: Bool

        func body(content: Content) -> some View {
            if isOn {
                content.phaseAnimator([false, true]) { view, exhaled in
                    // Only the strength breathes; the circle keeps its size
                    // next to send.
                    view.opacity(exhaled ? 0.8 : 1)
                } animation: { _ in
                    .easeInOut(duration: 0.9)
                }
            } else {
                content
            }
        }
    }

    /// The mask over the transcript: fully drawn, with a short fade at the
    /// bottom edge where it meets the composer. Only the alpha counts.
    struct CoachTranscriptFade: View {
        var body: some View {
            VStack(spacing: 0) {
                Rectangle()
                LinearGradient(
                    colors: [HLSurface.primary, HLSurface.primary.opacity(0)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: HLSpace.lg)
            }
        }
    }

    /// Why the last tap on the mic did not start a dictation: one quiet line
    /// inside the composer, above the field and the buttons, read out once by
    /// VoiceOver.
    struct CoachDictationHintLine: View {
        let hint: CoachDictationHint

        var body: some View {
            Text(verbatim: hint.text)
                .font(.hlFootnote)
                .foregroundStyle(HLText.secondary)
                // Grows only to the largest standard size, so the line and
                // the composer still fit above the keyboard at the
                // accessibility sizes; VoiceOver reads it out in full.
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("coach.dictation.hint")
        }
    }

    /// The standing statement that the Coach's answers are generated,
    /// fallible and not medical advice (build 273, App Review 1.2 / 5.1.1,
    /// 1.4.1). It stands under the welcome of a new conversation and goes
    /// once the first message is in the transcript; past that, the AI consent
    /// sheet and the first-launch disclaimer carry the medical framing.
    struct CoachAIGeneratedNote: View {
        var body: some View {
            Text("coach.aiGeneratedNote")
                .font(.hlCaption2)
                .foregroundStyle(HLText.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("coach.aiGeneratedNote")
        }
    }
#endif
