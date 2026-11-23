import SwiftUI

/// The rules of a composer's buttons, apart from the view so they can be
/// tested.
enum HLComposerRules {
    static func canSend(text: String, isBusy: Bool) -> Bool {
        !isBusy && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Send stands in the row while there is text, and stays (dimmed) while
    /// the answer to what was just sent is on its way.
    static func showsSend(text: String, isBusy: Bool) -> Bool {
        isBusy || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Lines the field grows to before it scrolls: fewer at the accessibility
    /// sizes, so field and keyboard still fit.
    static func lineLimit(at typeSize: DynamicTypeSize) -> ClosedRange<Int> {
        typeSize.isAccessibilitySize ? 1 ... 3 : 1 ... 6
    }
}

/// The circle of a composer button: 36 pt inside a 44 pt tap area, one
/// glyph size and weight. Send and a live microphone are the filled circle,
/// a resting microphone the quiet one. Disabled, it keeps its circle dimmed,
/// so the row never changes its rhythm.
struct HLComposerDisc: View {
    enum Style: Equatable, Sendable {
        case quiet
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

    @ViewBuilder private var disc: some View {
        switch (style, isEnabled) {
        case (.accent, true):
            Circle().fill(HLAccent.primary)
        case (.quiet, _), (.accent, false):
            ZStack {
                Circle().fill(HLSurface.secondary)
                Circle().fill(Color(uiColor: .secondarySystemFill))
            }
        }
    }
}

/// The one input line of a conversation (the coach, a document's chat): the
/// field in front, an optional accessory (the microphone) and send behind it,
/// in one quiet container, as in Messages.
///
/// Send appears only while there is something to send. The caller owns what
/// sending means; the bar only asks for it once per tap or return.
struct HLComposerBar<Accessory: View>: View {
    @Binding private var text: String
    private let prompt: Text
    private let isBusy: Bool
    private let identifier: String
    private let onSend: () -> Void
    private let accessory: Accessory

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        text: Binding<String>,
        prompt: Text,
        isBusy: Bool = false,
        identifier: String = "hl.composer",
        onSend: @escaping () -> Void,
        @ViewBuilder accessory: () -> Accessory
    ) {
        _text = text
        self.prompt = prompt
        self.isBusy = isBusy
        self.identifier = identifier
        self.onSend = onSend
        self.accessory = accessory()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: HLRadius.md, style: .continuous)
        HStack(alignment: .bottom, spacing: HLSpace.xs) {
            TextField(text: $text, prompt: prompt, axis: .vertical) { prompt }
                .lineLimit(HLComposerRules.lineLimit(at: dynamicTypeSize))
                .textFieldStyle(.plain)
                .font(.hlBody)
                .foregroundStyle(HLText.primary)
                .disabled(isBusy)
                .submitLabel(.send)
                .onSubmit(send)
                .padding(.vertical, HLSpace.md - HLSpace.xs)
                .frame(minHeight: HLHitTarget.minimum)
                .accessibilityIdentifier("\(identifier).field")
            accessory
            if HLComposerRules.showsSend(text: text, isBusy: isBusy) {
                Button(action: send) {
                    HLComposerDisc(systemImage: "arrow.up", style: .accent)
                }
                .buttonStyle(.plain)
                .disabled(!HLComposerRules.canSend(text: text, isBusy: isBusy))
                .accessibilityLabel(Text("hl.composer.send"))
                .accessibilityIdentifier("\(identifier).send")
                .transition(reduceMotion ? .opacity : .scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .padding(.leading, HLSpace.lg)
        .padding([.top, .bottom, .trailing], HLSpace.sm - HLSpace.xs)
        .background {
            shape.fill(HLSurface.secondary)
            shape.strokeBorder(HLColor.separator, lineWidth: HLCardSurface.hairlineWidth)
        }
        .animation(
            reduceMotion ? .easeOut(duration: 0.15) : .snappy(duration: 0.22),
            value: HLComposerRules.showsSend(text: text, isBusy: isBusy)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }

    private func send() {
        guard HLComposerRules.canSend(text: text, isBusy: isBusy) else { return }
        onSend()
    }
}

extension HLComposerBar where Accessory == EmptyView {
    init(
        text: Binding<String>,
        prompt: Text,
        isBusy: Bool = false,
        identifier: String = "hl.composer",
        onSend: @escaping () -> Void
    ) {
        self.init(text: text, prompt: prompt, isBusy: isBusy, identifier: identifier, onSend: onSend) { EmptyView() }
    }
}

#Preview("HLComposerBar") {
    @Previewable @State var text = "Wie war mein Schlaf?"
    VStack {
        Spacer()
        HLComposerBar(text: $text, prompt: Text(verbatim: "Frag etwas …")) {}
            .padding(.horizontal, HLLayout.pageMargin)
    }
    .background(HLSurface.primary)
}
