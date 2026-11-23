import SwiftUI

/// What the confirm button of a sheet stands for.
public enum HLSheetActionKind: Equatable, Sendable {
    /// Nothing to confirm: the sheet shows something and only closes.
    case closeOnly
    /// Keeps the input of a form.
    case save
    /// Creates the entry the form describes.
    case add
    /// Leaves a sheet whose changes already took effect. It closes with the
    /// cross like a sheet that only shows something: the changes hold, so a
    /// check mark beside the cross would do the same.
    case done
    /// Confirms a form whose step has a word of its own: send, connect,
    /// import. It looks and sits like every other confirm button.
    case confirm
}

/// The action in a sheet's bar. The caller says what it is, the scaffold
/// decides where it sits, what it looks like and how it is spoken.
public struct HLSheetAction: Sendable {
    public let kind: HLSheetActionKind
    public let isEnabled: Bool
    let perform: @MainActor () async -> Bool
    /// The word of a `.confirm` action. A plain value that is only read where
    /// the bar is built, which the compiler cannot see for this type.
    private nonisolated(unsafe) let ownWord: LocalizedStringKey?

    private init(
        kind: HLSheetActionKind,
        isEnabled: Bool,
        ownWord: LocalizedStringKey? = nil,
        perform: @escaping @MainActor () async -> Bool
    ) {
        self.kind = kind
        self.isEnabled = isEnabled
        self.ownWord = ownWord
        self.perform = perform
    }

    /// A sheet that only shows something: a close button, nothing to confirm.
    public static let none = HLSheetAction(kind: .closeOnly, isEnabled: true) { true }

    /// Keeps the input. `perform` returns `true` when the sheet may close.
    public static func save(
        isEnabled: Bool = true,
        perform: @escaping @MainActor () async -> Bool
    ) -> HLSheetAction {
        HLSheetAction(kind: .save, isEnabled: isEnabled, perform: perform)
    }

    /// Creates the entry. `perform` returns `true` when the sheet may close.
    public static func add(
        isEnabled: Bool = true,
        perform: @escaping @MainActor () async -> Bool
    ) -> HLSheetAction {
        HLSheetAction(kind: .add, isEnabled: isEnabled, perform: perform)
    }

    /// Confirms with a word of the caller's own, where neither "Save" nor
    /// "Add" says what happens. Only the spoken label changes: VoiceOver reads
    /// `word`, the check mark and its place stay. `perform` returns `true`
    /// when the sheet may close.
    public static func confirm(
        _ word: LocalizedStringKey,
        isEnabled: Bool = true,
        perform: @escaping @MainActor () async -> Bool
    ) -> HLSheetAction {
        HLSheetAction(kind: .confirm, isEnabled: isEnabled, ownWord: word, perform: perform)
    }

    /// How the confirm button is spoken, or `nil` when the sheet has none.
    public var confirmLabel: Text? {
        guard HLSheetBar.showsConfirm(for: kind) else { return nil }
        if let ownWord { return Text(ownWord) }
        return HLSheetBar.confirmWord(for: kind)?.text
    }

    /// Leaves a sheet that has nothing left to keep. `perform` runs when the
    /// cross is tapped, before the sheet goes.
    public static func done(perform: @escaping @MainActor () -> Void = {}) -> HLSheetAction {
        HLSheetAction(kind: .done, isEnabled: true) {
            perform()
            return true
        }
    }
}

/// The fixed rules of a sheet's bar, in one place.
public enum HLSheetBar {
    /// The identifier of the leading button on every sheet, unless the caller
    /// names its own. A UI test finds the button by it in any language.
    public static let closeIdentifier = "hl.sheet.close"

    /// The identifier of the trailing button on every sheet, unless the caller
    /// names its own.
    public static let confirmIdentifier = "hl.sheet.confirm"

    /// What happens when the leading button is tapped.
    public enum CloseStep: Equatable, Sendable {
        /// Work is under way: the sheet stays until it has ended.
        case locked
        /// Input would be lost: the sheet asks before it goes.
        case asksFirst
        /// Nothing to lose: the sheet goes.
        case leaves
    }

    /// Every sheet leaves through the cross at the leading edge, a sheet
    /// whose changes already hold as well.
    public static func showsClose(for _: HLSheetActionKind) -> Bool {
        true
    }

    /// Whether the trailing check mark stands in the bar. A sheet that only
    /// shows something and a sheet whose changes already hold have nothing
    /// to confirm.
    public static func showsConfirm(for kind: HLSheetActionKind) -> Bool {
        confirmWord(for: kind) != nil || kind == .confirm
    }

    /// What the leading button is called. Next to a save it cancels, on a
    /// sheet that only shows something it closes.
    public static func closeWord(for kind: HLSheetActionKind) -> HLControlWord {
        switch kind {
        case .save, .add, .confirm: .cancel
        case .closeOnly, .done: .close
        }
    }

    /// How the leading button is spoken. A sheet whose close stands for a
    /// decision (declining a consent, leaving a flow) brings the word for it;
    /// the sign and its place stay.
    public static func closeLabel(for kind: HLSheetActionKind, own word: LocalizedStringKey? = nil) -> Text {
        if let word { return Text(word) }
        return closeWord(for: kind).text
    }

    /// What the trailing button is called where the kind fixes the word.
    /// `nil` for a sheet without one and for `.confirm`, which brings its own
    /// (``HLSheetAction/confirmLabel``).
    public static func confirmWord(for kind: HLSheetActionKind) -> HLControlWord? {
        switch kind {
        case .closeOnly, .confirm, .done: nil
        case .save: .save
        case .add: .add
        }
    }

    /// Closing asks first as soon as input would be lost.
    public static func closeAsksFirst(isDirty: Bool) -> Bool {
        isDirty
    }

    /// What a tap on the leading button does. Running work comes first: a
    /// sheet that is saving neither closes nor asks whether to discard what
    /// it is about to keep.
    public static func closeStep(isDirty: Bool, isBusy: Bool) -> CloseStep {
        if isBusy { return .locked }
        return closeAsksFirst(isDirty: isDirty) ? .asksFirst : .leaves
    }
}

/// Remembers how a sheet was left, so its caller hears of a close once and
/// never after a confirm. A second tap while the sheet slides away would
/// otherwise report the close twice.
@MainActor
final class HLSheetExit {
    private var isSettled = false

    /// The action went through: whatever happens now is not a close.
    func confirmed() {
        isSettled = true
    }

    /// The sheet was closed without confirming. Runs `onClose` the first time
    /// only.
    func closed(_ onClose: (@MainActor () -> Void)?) {
        guard !isSettled else { return }
        isSettled = true
        onClose?()
    }
}

/// Runs a sheet's action, one run at a time.
@MainActor
@Observable
public final class HLSheetActionRunner {
    public private(set) var isRunning = false

    public init() {}

    /// Runs the action and reports whether the sheet may close. A second tap
    /// while a run is under way does nothing, so a save cannot go out twice.
    public func run(_ action: HLSheetAction) async -> Bool {
        guard !isRunning, action.isEnabled else { return false }
        isRunning = true
        defer { isRunning = false }
        return await action.perform()
    }
}

/// The frame of every sheet with a header.
///
/// It brings the navigation stack, the inline title, the close button at the
/// leading edge and the confirm button at the trailing edge, the detents and
/// the grabber, the app background and the question before input is thrown
/// away. Further bar buttons (share, edit) go on the content with a normal
/// `toolbar`, never on the two places the scaffold owns.
///
/// `isBusy` is for work the content started itself (an upload from a row, a
/// request behind a button in the page). While it runs the sheet cannot be
/// closed and does not ask about discarding. Work behind the bar's own action
/// needs no flag, the scaffold knows about it.
///
/// `onClose` runs when the sheet is left through the close button, after the
/// discard question where there is one. It does not run after a confirm and
/// not for a swipe down; `sheet(onDismiss:)` hears of every way out.
public struct HLSheetScaffold<Content: View>: View {
    let titleText: Text
    private let size: HLSheetSize
    private let detent: Binding<PresentationDetent>?
    private let action: HLSheetAction
    private let isDirty: Bool
    private let isBusy: Bool
    private let closeWord: LocalizedStringKey?
    let closeIdentifier: String
    let confirmIdentifier: String
    private let onClose: (@MainActor () -> Void)?
    private let content: Content

    @Environment(\.dismiss) private var dismiss
    @State private var runner = HLSheetActionRunner()
    @State private var exit = HLSheetExit()
    @State private var asksBeforeDiscard = false

    public init(
        _ title: LocalizedStringKey,
        size: HLSheetSize = .form,
        action: HLSheetAction = .none,
        isDirty: Bool = false,
        isBusy: Bool = false,
        closeWord: LocalizedStringKey? = nil,
        closeIdentifier: String = HLSheetBar.closeIdentifier,
        confirmIdentifier: String = HLSheetBar.confirmIdentifier,
        onClose: (@MainActor () -> Void)? = nil,
        detent: Binding<PresentationDetent>? = nil,
        @ViewBuilder content: () -> Content
    ) {
        titleText = Text(title)
        self.size = size
        self.action = action
        self.isDirty = isDirty
        self.isBusy = isBusy
        self.closeWord = closeWord
        self.closeIdentifier = closeIdentifier
        self.confirmIdentifier = confirmIdentifier
        self.onClose = onClose
        self.detent = detent
        self.content = content()
    }

    /// A sheet titled with data: a name, a value, a label from the server.
    /// The title is shown as it is and never looked up in the catalog, so
    /// "50 %" stays "50 %" and a name that happens to be a key stays a name.
    public init(
        verbatim title: String,
        size: HLSheetSize = .form,
        action: HLSheetAction = .none,
        isDirty: Bool = false,
        isBusy: Bool = false,
        closeWord: LocalizedStringKey? = nil,
        closeIdentifier: String = HLSheetBar.closeIdentifier,
        confirmIdentifier: String = HLSheetBar.confirmIdentifier,
        onClose: (@MainActor () -> Void)? = nil,
        detent: Binding<PresentationDetent>? = nil,
        @ViewBuilder content: () -> Content
    ) {
        titleText = Text(verbatim: title)
        self.size = size
        self.action = action
        self.isDirty = isDirty
        self.isBusy = isBusy
        self.closeWord = closeWord
        self.closeIdentifier = closeIdentifier
        self.confirmIdentifier = confirmIdentifier
        self.onClose = onClose
        self.detent = detent
        self.content = content()
    }

    /// Work under way, whoever started it.
    private var isWorking: Bool {
        isBusy || runner.isRunning
    }

    public var body: some View {
        NavigationStack {
            content
                .hlSheetStack()
                .environment(\.defaultMinListRowHeight, HLLayout.rowPitch)
                .scrollContentBackground(.hidden)
                .background(HLSurface.primary.ignoresSafeArea())
                // A scrolled form showed an opaque band with a hard lower
                // edge under the bar; the soft edge fades like on the pages.
                .scrollEdgeEffectStyle(.soft, for: .top)
                .navigationTitle(titleText)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { bar }
                .hlDiscardGuard(
                    isDirty: isDirty,
                    isSaving: isWorking,
                    isPresented: $asksBeforeDiscard
                ) { leave() }
        }
        .modifier(HLScaffoldPresentation(size: size, detent: detent))
    }

    @ToolbarContentBuilder
    private var bar: some ToolbarContent {
        if HLSheetBar.showsClose(for: action.kind) {
            ToolbarItem(placement: .cancellationAction) {
                Button(role: .close) { close() }
                    .accessibilityLabel(HLSheetBar.closeLabel(for: action.kind, own: closeWord))
                    .accessibilityIdentifier(closeIdentifier)
                    .disabled(isWorking)
            }
            .hlVisibilityPriority(.primary)
        }
        if let spoken = action.confirmLabel {
            ToolbarItem(placement: .confirmationAction) {
                if runner.isRunning {
                    ProgressView()
                } else {
                    Button(role: .confirm) { confirm() }
                        .accessibilityLabel(spoken)
                        .accessibilityIdentifier(confirmIdentifier)
                        .disabled(!action.isEnabled || isBusy)
                }
            }
            // In a narrow window the form's own actions stay; a screen's
            // extra bar items fold first.
            .hlVisibilityPriority(.primary)
        }
    }

    private func close() {
        switch HLSheetBar.closeStep(isDirty: isDirty, isBusy: isWorking) {
        case .locked: break
        case .asksFirst: asksBeforeDiscard = true
        case .leaves where action.kind == .done: finish()
        case .leaves: leave()
        }
    }

    /// The cross of a sheet whose changes already hold: the caller's last
    /// step runs, then the sheet goes like after a confirm.
    private func finish() {
        Task {
            if await runner.run(action) {
                exit.confirmed()
                dismiss()
            }
        }
    }

    /// Leaves without confirming and tells the caller.
    private func leave() {
        exit.closed(onClose)
        dismiss()
    }

    private func confirm() {
        Task {
            if await runner.run(action) {
                exit.confirmed()
                dismiss()
            }
        }
    }
}

public extension View {
    /// The confirm of a page pushed inside a sheet (an edit page under a
    /// form): the check mark at the trailing edge with the action's spoken
    /// word, run once at a time, the page goes back when `perform` returns
    /// `true`. The system back button stays at the leading edge, so the page
    /// needs no "Save" in words and no own back.
    ///
    /// `hidesUntilChanged`: on a settings page that is not a form, a grey
    /// check mark with nothing to save read as a button without a purpose;
    /// there it appears with the first change.
    func hlConfirmBar(
        _ action: HLSheetAction,
        identifier: String = HLSheetBar.confirmIdentifier,
        hidesUntilChanged: Bool = false
    ) -> some View {
        modifier(HLConfirmBarModifier(action: action, identifier: identifier, hidesUntilChanged: hidesUntilChanged))
    }
}

/// The trailing confirm of a pushed page, the twin of the scaffold's own.
struct HLConfirmBarModifier: ViewModifier {
    let action: HLSheetAction
    let identifier: String
    var hidesUntilChanged = false

    /// Whether the bar shows the confirm at all: always for a form, on a
    /// settings page only while there is something to save or it is saving.
    nonisolated static func showsConfirm(isEnabled: Bool, isRunning: Bool, hidesUntilChanged: Bool) -> Bool {
        !hidesUntilChanged || isEnabled || isRunning
    }

    @Environment(\.dismiss) private var dismiss
    @State private var runner = HLSheetActionRunner()

    func body(content: Content) -> some View {
        content.toolbar {
            if let spoken = action.confirmLabel,
               Self.showsConfirm(isEnabled: action.isEnabled, isRunning: runner.isRunning, hidesUntilChanged: hidesUntilChanged)
            {
                ToolbarItem(placement: .confirmationAction) {
                    if runner.isRunning {
                        ProgressView()
                    } else {
                        Button(role: .confirm) { confirm() }
                            .accessibilityLabel(spoken)
                            .accessibilityIdentifier(identifier)
                            .disabled(!action.isEnabled)
                    }
                }
                .hlVisibilityPriority(.primary)
            }
        }
    }

    private func confirm() {
        Task {
            if await runner.run(action) {
                dismiss()
            }
        }
    }
}

/// The scaffold's detents: fixed by its size, or moved by the caller when a
/// sheet grows on its own (the mood check-in after an entry is made).
/// `detent` must be one of `size.detents`.
private struct HLScaffoldPresentation: ViewModifier {
    let size: HLSheetSize
    let detent: Binding<PresentationDetent>?

    func body(content: Content) -> some View {
        if let detent {
            content.hlSheetPresentation(size, selection: detent)
        } else {
            content.hlSheetPresentation(size)
        }
    }
}

public extension View {
    /// Surface and insets of a row in a `List` or `Form`. Put it on each
    /// `Section` (or on a `Group` around them): the rows then stand on the app
    /// background like a card does on a page, with the card's inset at the
    /// sides and half the row spacing above and below. No line stands between
    /// two rows, as none stands between the rows of a card.
    func hlFormRowSurface() -> some View {
        listRowBackground(HLSurface.secondary)
            .listRowInsets(HLFormRowMetrics.insets)
            .listRowSeparator(HLFormRowMetrics.separator)
    }
}

/// Published measures of a form row, so the row grid can be checked.
public enum HLFormRowMetrics {
    /// The one switch for the line between two rows of a list or form.
    /// Setting this to `.automatic` brings the system separator back on every
    /// form at once.
    public static let separator: Visibility = .hidden

    public static let insets = EdgeInsets(
        top: HLLayout.rowSpacing / 2,
        leading: HLLayout.cardInset,
        bottom: HLLayout.rowSpacing / 2,
        trailing: HLLayout.cardInset
    )
}

#Preview("HLSheetScaffold, light") {
    HLSheetScaffoldPreview()
        .preferredColorScheme(.light)
}

#Preview("HLSheetScaffold, dark") {
    HLSheetScaffoldPreview()
        .preferredColorScheme(.dark)
}

#Preview("HLSheetScaffold, largest type") {
    HLSheetScaffoldPreview()
        .dynamicTypeSize(.accessibility5)
}

private struct HLSheetScaffoldPreview: View {
    @State private var name = ""
    @State private var reminds = true

    var body: some View {
        HLSheetScaffold(
            "Add medication",
            action: .add(isEnabled: !name.isEmpty) { true },
            isDirty: !name.isEmpty
        ) {
            Form {
                Group {
                    Section {
                        TextField("Medications", text: $name)
                    }
                    Section {
                        Toggle("Daily", isOn: $reminds)
                    }
                }
                .hlFormRowSurface()
            }
        }
    }
}
