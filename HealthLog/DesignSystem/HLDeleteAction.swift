import SwiftUI

/// How something is deleted.
///
/// The caller only names the step. A single entry that can be brought back
/// goes at once and the undo hint appears; a container with history behind it
/// asks first. Whether the swipe may run through, what the button says and
/// how the question looks is decided here. There are three ways in: the swipe
/// on a row (`hlSwipeDelete`), the button (``HLDeleteButton``) and the entry
/// of a menu (``HLDeleteMenuItem``).
public struct HLDeleteAction {
    /// The sign next to the word on a swipe and in a menu.
    public static let deleteSymbol = "trash"

    enum Step {
        case undoable
        case confirmed(title: Text, message: Text?)
    }

    let step: Step
    /// The word on the control and on the red answer of the question.
    let word: LocalizedStringKey
    /// The sign that goes with ``word``.
    let symbol: String
    let perform: @MainActor () async -> Void

    /// Deletes at once. `perform` removes the entry through its store, which
    /// offers the way back.
    public static func undoable(perform: @escaping @MainActor () async -> Void) -> HLDeleteAction {
        HLDeleteAction(step: .undoable, word: HLControlWord.delete.key, symbol: deleteSymbol, perform: perform)
    }

    /// Asks first, then deletes.
    ///
    /// `word` is for the few red actions that end something without deleting
    /// an entry (revoking a session, a token, a share link). The control and
    /// the red answer then say that word, and `symbol` is the sign for it.
    /// The question itself, its shape and its Cancel stay the same.
    public static func confirmed(
        title: LocalizedStringKey,
        message: LocalizedStringKey? = nil,
        word: LocalizedStringKey = HLControlWord.delete.key,
        symbol: String = HLDeleteAction.deleteSymbol,
        perform: @escaping @MainActor () async -> Void
    ) -> HLDeleteAction {
        HLDeleteAction(
            step: .confirmed(title: Text(title), message: message.map { Text($0) }),
            word: word,
            symbol: symbol,
            perform: perform
        )
    }

    /// Asks first with a question built from data: the name of the entry, a
    /// count the caller has already put into words. Title and message are
    /// shown as they are and never looked up in the catalog.
    public static func confirmed(
        verbatim title: String,
        message: String? = nil,
        word: LocalizedStringKey = HLControlWord.delete.key,
        symbol: String = HLDeleteAction.deleteSymbol,
        perform: @escaping @MainActor () async -> Void
    ) -> HLDeleteAction {
        HLDeleteAction(
            step: .confirmed(title: Text(verbatim: title), message: message.map { Text(verbatim: $0) }),
            word: word,
            symbol: symbol,
            perform: perform
        )
    }

    public var requiresConfirmation: Bool {
        switch step {
        case .undoable: false
        case .confirmed: true
        }
    }

    /// A swipe to the end deletes only where nothing is asked: a question
    /// after a finished gesture reads as if the row were already gone.
    public var allowsFullSwipe: Bool {
        !requiresConfirmation
    }

    /// Carries out the deletion itself, without a question.
    @MainActor
    public func run() async {
        await perform()
    }

    var question: (title: Text, message: Text?)? {
        switch step {
        case .undoable: nil
        case let .confirmed(title, message): (title, message)
        }
    }

    /// The red answer of the question, and how a control without words of
    /// its own is spoken.
    var wordText: Text {
        Text(word)
    }
}

/// Takes a deletion from the control that starts it to the question, and
/// keeps it from running twice.
///
/// A tap on a delete control ends here. An undoable deletion starts at once,
/// a confirmed one waits for the answer. While a deletion runs, every further
/// tap does nothing.
@MainActor
@Observable
public final class HLDeleteRunner {
    /// `true` from the tap until `perform` has returned.
    public private(set) var isRunning = false
    /// The deletion the question is about. It stays after the answer, so the
    /// words do not vanish while the question fades.
    private(set) var asked: HLDeleteAction?
    var isAsking = false

    public init() {}

    /// What a tap on a delete control does: ask, or delete.
    func trigger(_ action: HLDeleteAction) {
        guard !isRunning else { return }
        if action.requiresConfirmation {
            asked = action
            isAsking = true
        } else {
            start(action)
        }
    }

    /// The answer "delete" to the question.
    func confirm() {
        isAsking = false
        guard let asked, !isRunning else { return }
        start(asked)
    }

    /// Carries out the deletion and reports whether it ran. A second call
    /// while one is under way does nothing.
    @discardableResult
    public func run(_ action: HLDeleteAction) async -> Bool {
        guard !isRunning else { return false }
        isRunning = true
        defer { isRunning = false }
        await action.run()
        return true
    }

    /// Locks before the task starts: two taps in the same turn of the run
    /// loop would otherwise both pass the check.
    private func start(_ action: HLDeleteAction) {
        isRunning = true
        Task {
            await action.run()
            isRunning = false
        }
    }
}

/// The question in front of a confirmed deletion. An undoable one has none.
private struct HLDeleteConfirmation: ViewModifier {
    @Bindable var runner: HLDeleteRunner

    func body(content: Content) -> some View {
        let question = runner.asked?.question
        content.hlConfirmDestructive(
            question?.title ?? Text(verbatim: ""),
            isPresented: $runner.isAsking,
            message: question?.message,
            confirm: runner.asked?.wordText ?? HLControlWord.delete.text,
            action: { runner.confirm() }
        )
    }
}

/// The place that asks for the delete entries of the menus below it.
private struct HLDeleteConfirmationScope: ViewModifier {
    @State private var runner = HLDeleteRunner()

    func body(content: Content) -> some View {
        content
            .environment(runner)
            .modifier(HLDeleteConfirmation(runner: runner))
    }
}

private struct HLSwipeDelete<More: View>: ViewModifier {
    let action: HLDeleteAction
    let more: More
    @State private var runner = HLDeleteRunner()

    func body(content: Content) -> some View {
        content
            .swipeActions(edge: .trailing, allowsFullSwipe: action.allowsFullSwipe) {
                if action.requiresConfirmation {
                    // Without the destructive role: the system would clear
                    // the row away before the question is answered.
                    Button { runner.trigger(action) } label: { label }
                        .tint(HLColor.statusBad)
                } else {
                    // The colour is set here as well: an inherited tint
                    // would otherwise paint the action in the app's ink.
                    Button(role: .destructive) { runner.trigger(action) } label: { label }
                        .tint(HLColor.statusBad)
                }
                more
            }
            .modifier(HLDeleteConfirmation(runner: runner))
    }

    private var label: some View {
        Label(action.word, systemImage: action.symbol)
    }
}

public extension View {
    /// The swipe to delete on a list row.
    func hlSwipeDelete(_ action: HLDeleteAction) -> some View {
        modifier(HLSwipeDelete(action: action, more: EmptyView()))
    }

    /// The swipe to delete with further actions on the same edge. Deleting
    /// stays outermost, `more` follows towards the row in the order written.
    /// A second `swipeActions` on the same edge would not join this one, so
    /// everything for the trailing edge goes here.
    func hlSwipeDelete(
        _ action: HLDeleteAction,
        @ViewBuilder also more: () -> some View
    ) -> some View {
        modifier(HLSwipeDelete(action: action, more: more()))
    }

    /// Asks the question for every ``HLDeleteMenuItem`` below this view.
    ///
    /// It belongs on the element around the menu, the page or the row, never
    /// on the entry: a menu is gone the moment an entry is tapped, and a
    /// question attached to it goes with it.
    func hlDeleteConfirmation() -> some View {
        modifier(HLDeleteConfirmationScope())
    }
}

/// Deleting as an entry of a menu.
///
/// An undoable deletion runs at once. A confirmed one needs
/// `hlDeleteConfirmation()` on the element around the menu, which asks the
/// question. Without it the entry deletes nothing.
public struct HLDeleteMenuItem: View {
    private let action: HLDeleteAction
    @Environment(HLDeleteRunner.self) private var runner: HLDeleteRunner?

    public init(_ action: HLDeleteAction) {
        self.action = action
    }

    public var body: some View {
        Button(role: .destructive, action: trigger) {
            Label(action.word, systemImage: action.symbol)
        }
    }

    private func trigger() {
        if let runner {
            runner.trigger(action)
        } else if action.requiresConfirmation {
            HLLog.ui.warning("HLDeleteMenuItem needs hlDeleteConfirmation() around its menu to ask first")
        } else {
            Task { await action.run() }
        }
    }
}

/// The delete button outside a swipe and a menu.
///
/// The call names the form, because the button cannot see where it stands:
/// `.row` is a row of a `List` or `Form` with red words, flush with the rows
/// around it. `.page` is the button on an ``HLPage``: the destructive variant
/// of ``HLButton``, an outline with red words. `.icon` is the red sign alone
/// at the end of a row that has no room for words. `.bar` is the entry of a
/// toolbar or a selection bar. None of them is a red surface, and no other
/// button is one.
public struct HLDeleteButton: View {
    public enum Form: Sendable {
        case row
        case page
        /// The sign alone, on a touch area of at least 44 by 44 points. It is
        /// spoken with the title.
        case icon
        /// Sign and title for a bar. The bar decides which of the two it
        /// shows. A question is asked by the `hlDeleteConfirmation()` around
        /// the screen where there is one: a bar may be rebuilt while its own
        /// question is up.
        case bar
        /// Takes one element out of a list being edited (a time, a header,
        /// an ingredient): the red minus at the leading edge of the row, as
        /// in the system's edit mode, on a 44 pt tap area. Spoken "Remove"
        /// unless a title is given. Pair it with an undoable action.
        case remove
    }

    /// The sign of ``Form/remove``.
    public static let removeSymbol = "minus.circle.fill"

    private let title: LocalizedStringKey?
    private let form: Form
    private let action: HLDeleteAction
    @State private var runner = HLDeleteRunner()
    @Environment(HLDeleteRunner.self) private var scopeRunner: HLDeleteRunner?

    /// - Parameter title: the words on the button. Without one the button
    ///   says the word of its action, "Delete" unless the action brings its
    ///   own.
    public init(
        _ title: LocalizedStringKey? = nil,
        form: Form,
        action: HLDeleteAction
    ) {
        self.title = title
        self.form = form
        self.action = action
    }

    /// What the button says, and how the sign alone is spoken.
    var label: Text {
        if let title { return Text(title) }
        return form == .remove ? Text("Remove") : action.wordText
    }

    private var activeRunner: HLDeleteRunner {
        form == .bar ? scopeRunner ?? runner : runner
    }

    public var body: some View {
        Group {
            switch form {
            case .row:
                Button(role: .destructive) { runner.trigger(action) } label: { rowLabel }
                    .buttonStyle(.plain)
                    .disabled(runner.isRunning)
            case .page:
                HLButton(title ?? action.word, variant: .destructive, isLoading: runner.isRunning) {
                    runner.trigger(action)
                }
            case .icon:
                Button { runner.trigger(action) } label: { iconLabel }
                    .buttonStyle(.plain)
                    .disabled(runner.isRunning)
                    .accessibilityLabel(label)
            case .remove:
                Button { runner.trigger(action) } label: { removeLabel }
                    .buttonStyle(.plain)
                    .disabled(runner.isRunning)
                    .accessibilityLabel(label)
            case .bar:
                // Without the destructive role, like the confirmed swipe: a
                // bar clears its selection for a destructive button before
                // the question is answered.
                Button { activeRunner.trigger(action) } label: {
                    Label { label } icon: { Image(systemName: action.symbol) }
                }
                .tint(HLColor.statusBad)
                .foregroundStyle(HLColor.statusBad)
                .disabled(activeRunner.isRunning)
            }
        }
        .modifier(HLDeleteConfirmation(runner: runner))
    }

    private var rowLabel: some View {
        label
            .font(HLRowTitle.font)
            .foregroundStyle(HLColor.statusBad)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: HLLayout.rowMinHeight, alignment: .leading)
            .contentShape(Rectangle())
    }

    private var removeLabel: some View {
        Image(systemName: Self.removeSymbol)
            .font(.hlTitle3)
            .foregroundStyle(HLColor.statusBad)
            .hlMinimumHitTarget()
    }

    private var iconLabel: some View {
        Image(systemName: action.symbol)
            .font(HLRowTitle.font)
            .foregroundStyle(HLColor.statusBad)
            .hlMinimumHitTarget()
    }
}

#Preview("HLDeleteAction, light") {
    HLDeleteActionPreview()
        .preferredColorScheme(.light)
}

#Preview("HLDeleteAction, dark") {
    HLDeleteActionPreview()
        .preferredColorScheme(.dark)
}

#Preview("HLDeleteAction, largest type") {
    HLDeleteActionPreview()
        .dynamicTypeSize(.accessibility5)
}

private struct HLDeleteActionPreview: View {
    var body: some View {
        NavigationStack {
            List {
                Section {
                    HLRowLayout(title: "Weight", subtitle: "Today")
                        .hlSwipeDelete(.undoable {})
                    HLRowLayout(title: "Mood", subtitle: "Yesterday")
                        .hlSwipeDelete(.undoable {}) {
                            Button {} label: { Label(HLControlWord.edit.key, systemImage: "pencil") }
                        }
                    HLRowLayout(title: "Medications", indicator: .disclosure)
                        .hlSwipeDelete(.confirmed(title: "Delete entry?") {})
                }
                .hlFormRowSurface()
                Section {
                    HLDeleteButton(form: .row, action: .confirmed(title: "Delete entry?") {})
                }
                .hlFormRowSurface()
                Section {
                    HLRowLayout(title: "Blood pressure", subtitle: "Monday") {
                        HLDeleteButton(form: .icon, action: .confirmed(title: "Delete entry?") {})
                    }
                }
                .hlFormRowSurface()
                Section {
                    HLDeleteButton(form: .page, action: .confirmed(title: "Delete entry?") {})
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }
            .hlPageMargins()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HLIconButton(systemImage: "ellipsis", label: "More", menu: {
                        HLDeleteMenuItem(.confirmed(title: "Delete entry?") {})
                    })
                }
                ToolbarItem(placement: .bottomBar) {
                    HLDeleteButton(form: .bar, action: .confirmed(title: "Delete entry?") {})
                }
            }
            .hlDeleteConfirmation()
        }
    }
}
